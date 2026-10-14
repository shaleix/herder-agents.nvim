-- skill 列表获取层（配置驱动，按当前工具取数；completion/skills.lua 只是
-- blink.cmp 适配层，补全相关的异步/缓存/降级策略全部收口在本模块）。
--
-- 数据源由 tools.<name>.skills 配置决定，两种模式：
--   api 模式  skills.api = { argv }        → 执行 CLI，解析 JSON（{data:[...]}，
--             兼容 {name, location} 形状）；配置了 api 时优先
--   fs  模式  skills.user / skills.project（+ project_up）→ 递归发现
--             <目录>/SKILL.md，frontmatter 的 name/description 可覆盖目录名
-- api 与 fs 字段可共存：api 拉取失败（进程出错/非零退出/大响应经管道被截断
-- 导致 JSON 不完整/缺 data）时自动回退 fs 目录扫描，并每会话每工具告警一次。
-- 未配置 skills 的工具没有 skill 列表（list 直接回 {}）。
--
-- 缓存按 工具 + cwd（含任一 fs 字段的配置）分键，ttl 取
-- config.options.completion.skill_ttl：
--   - 缓存新鲜：同步回调缓存
--   - 缓存过期：先回调旧列表，同时后台刷新
--   - 无缓存：回调挂起，首拉完成后统一 flush（pending/in_flight 模式，每键一份）
-- 任何失败都静默降级（回旧列表或 {}）——补全绝不报错、绝不阻塞。
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local uv = vim.uv or vim.loop
local MAX_SCAN_DEPTH = 8 -- fs 递归扫描深度上限（防符号链接环/超深层级）

-- 每键一份缓存：{ items, time, in_flight, pending }
local cache = {}

local function ttl()
  local c = config.options.completion
  return (c and c.skill_ttl) or 300
end

--- 工具的 skills 配置（config.options.tools[tool].skills），未配置返回 nil
---@param tool string
---@return table|nil
function M.spec(tool)
  local t = (config.options.tools or {})[tool]
  return t and t.skills or nil
end

--- skill 补全的触发字符（默认 "@"）
---@param tool string
---@return string
function M.trigger(tool)
  local s = M.spec(tool)
  return (s and s.trigger) or "@"
end

--- 所有配置了 skills 的工具的触发字符去重并集（按 tool_order 顺序，blink 注册用）
---@return string[]
function M.triggers()
  local seen, out = {}, {}
  for _, tool in ipairs(config.options.tool_order or {}) do
    if M.spec(tool) then
      local ch = M.trigger(tool)
      if not seen[ch] then
        seen[ch] = true
        table.insert(out, ch)
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- fs 模式：目录发现
-- ---------------------------------------------------------------------------

-- 读 SKILL.md 头部的 frontmatter（前导 --- 行之间），取单行 name:/description:。
-- 只读文件头部（前 30 行），全部 pcall 包裹；无 frontmatter 返回 {}
local function parse_frontmatter(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 30)
  if not ok or type(lines) ~= "table" or (lines[1] or ""):match("^%s*-%-%-%s*$") == nil then
    return {}
  end
  local meta = {}
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%s*-%-%-%s*$") then
      break -- frontmatter 结束
    end
    local key, value = line:match("^([%w_-]+)%s*:%s*(.-)%s*$")
    if key == "name" and meta.name == nil then
      meta.name = value
    elseif key == "description" and meta.description == nil then
      meta.description = value
    end
  end
  return meta
end

-- 递归扫一个 skill 根目录：含 SKILL.md 的目录是一个 skill（不再深入），
-- 无 SKILL.md 的目录继续递归；跳过 dot 目录，深度封顶。每层排序保证确定性
local function scan_root(root, out, depth)
  if depth > MAX_SCAN_DEPTH then
    return
  end
  -- 先用 fs_stat 静默判存在（readdir 对不存在的路径会打 E484，pcall 只拦异常不拦输出）
  local ok_st, st = pcall(uv.fs_stat, root)
  if not ok_st or not st or st.type ~= "directory" then
    return
  end
  local ok, names = pcall(vim.fn.readdir, root)
  if not ok or type(names) ~= "table" then
    return
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if name:sub(1, 1) ~= "." then
      local dir = root .. "/" .. name
      local skill_path = dir .. "/SKILL.md"
      local ok_file, st = pcall(uv.fs_stat, skill_path)
      if ok_file and st and st.type == "file" then
        -- SKILL.md 所在目录即一个 skill：id = frontmatter name（回落目录名）
        local meta = parse_frontmatter(skill_path)
        local id = (meta.name and meta.name ~= "" and meta.name) or name
        table.insert(out, {
          id = id,
          name = id,
          description = meta.description or "",
          path = skill_path,
        })
      else
        local ok_dir, dst = pcall(uv.fs_stat, dir)
        if ok_dir and dst and dst.type == "directory" then
          scan_root(dir, out, depth + 1)
        end
      end
    end
  end
end

-- fs 模式的扫描根序列：user 目录（~ 展开，配置顺序）++ project 根。
-- project_up 时从最上层祖先到 cwd 逐层解析 project 名（越近的层级越晚扫，
-- first-discovered-wins ⇒ user > 祖先 > cwd，同 id 不覆盖）；否则仅 cwd。
-- 上界是 git 仓库根（不在仓库则到文件系统根）
local function fs_roots(spec, cwd)
  local roots = {}
  local function add(path)
    if path and path ~= "" and not vim.tbl_contains(roots, path) then
      table.insert(roots, path)
    end
  end
  for _, dir in ipairs(spec.user or {}) do
    local ok, expanded = pcall(vim.fn.expand, dir)
    add(ok and expanded or dir)
  end
  local project = spec.project or {}
  if #project > 0 then
    -- 上界是 git 仓库根（不在仓库则到文件系统根）；头插让祖先在前（越近越晚扫）
    local levels
    if spec.project_up then
      levels = {}
      local stop = "/"
      local ok, git_root = pcall(vim.fs.root, cwd, ".git")
      if ok and git_root then
        stop = git_root
      end
      local level = cwd
      while true do
        table.insert(levels, 1, level)
        if level == stop then
          break
        end
        local parent = vim.fs.dirname(level)
        if not parent or parent == level then
          break -- 到文件系统根
        end
        level = parent
      end
    else
      levels = { cwd }
    end
    for _, level in ipairs(levels) do
      for _, name in ipairs(project) do
        -- 文件系统根（"/"）不再追加斜杠，避免 "//xxx"
        add(level .. (level:sub(-1) == "/" and "" or "/") .. name)
      end
    end
  end
  return roots
end

-- fs 列表：各根依次递归扫描，聚合成规范化条目（同 id 先发现者保留）
local function fs_list(spec, cwd)
  local out, seen = {}, {}
  for _, root in ipairs(fs_roots(spec, cwd)) do
    local found = {}
    pcall(scan_root, root, found, 0)
    for _, entry in ipairs(found) do
      if not seen[entry.id] then
        seen[entry.id] = true
        table.insert(out, entry)
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- api 模式：CLI JSON 列表
-- ---------------------------------------------------------------------------

-- 执行 skills.api 的 argv，解析响应 {data:[...]}（兼容 {name, location} 形状）。
-- 失败（非零退出/非 JSON/缺 data）回调 nil，由调用方决定回退（fs 扫描/旧列表/{}）
local function api_fetch(spec, on_done)
  local argv = spec.api
  if type(argv) ~= "table" or #argv == 0 then
    on_done(nil)
    return
  end
  utils.exec_async(argv, function(r)
    local entries = nil
    if r.code == 0 and r.stdout ~= "" then
      local ok, decoded = pcall(vim.json.decode, r.stdout)
      if ok and type(decoded) == "table" and type(decoded.data) == "table" then
        entries = {}
        for _, e in ipairs(decoded.data) do
          if type(e) == "table" then
            local id = e.id or e.name
            if type(id) == "string" and id ~= "" then
              table.insert(entries, {
                id = id,
                name = e.name or id,
                description = e.description or "",
                path = e.path or e.location or "",
              })
            end
          end
        end
      end
    end
    on_done(entries)
  end)
end

-- ---------------------------------------------------------------------------
-- 缓存与公开 API
-- ---------------------------------------------------------------------------

-- 缓存键：工具 + \0 + （spec 含任一 fs 字段则追加 cwd —— 目录扫描结果与 cwd
-- 相关；纯 api 模式为空 —— 与 cwd 无关）
local function cache_key(tool, spec)
  local suffix = ""
  if spec.user or spec.project then
    suffix = vim.fn.getcwd()
  end
  return tool .. "\0" .. suffix
end

-- api 拉取失败的一次性告警（每会话每工具至多一次；成功/合法空列表不告警）。
-- 说明可能原因（CLI 大响应经管道输出被截断 → 退出码 0 但 JSON 不完整）与
-- 回退后果（有 fs 目录 → 目录扫描；没有 → 空列表）
local warned = {}
local function warn_api_failure(tool, has_fs)
  if warned[tool] then
    return
  end
  warned[tool] = true
  utils.warn(
    ("skill 列表获取失败（%s api 输出被截断或非法 JSON），已回退%s"):format(
      tool,
      has_fs and "目录扫描（仅用户/项目级 skill）" or "空列表"
    )
  )
end

--- list(tool, on_done)：回调规范化条目 { {id, name, description, path}, ... }。
--- 新鲜缓存同步回调；过期先回旧列表 + 后台刷新；无缓存挂起回调，完成后统一
--- flush。任何失败静默降级（旧列表或 {}）
---@param tool string
---@param on_done fun(entries: table)
function M.list(tool, on_done)
  local spec = M.spec(tool)
  -- 未配置 skills 的工具：无 skill 补全，直接空列表
  if not spec then
    if on_done then
      pcall(on_done, {})
    end
    return
  end

  local key = cache_key(tool, spec)
  local c = cache[key]
  if c and c.items and os.time() - c.time < ttl() then
    if on_done then
      pcall(on_done, c.items) -- 新鲜：同步回缓存
    end
    return
  end

  if c and c.items then
    if on_done then
      pcall(on_done, c.items) -- 过期：先回旧列表，同时后台刷新
    end
  else
    if not c then
      c = { items = nil, time = 0, in_flight = false, pending = {} }
      cache[key] = c
    end
    if on_done then
      table.insert(c.pending, on_done) -- 首拉未完成：挂起，完成后统一 flush
    end
  end

  if not c.in_flight then
    c.in_flight = true
    local finish = function(entries)
      if type(entries) == "table" then
        c.items = entries
        c.time = os.time()
      end
      -- 失败也 flush（回 {} 或旧列表）：补全不报错、不阻塞
      c.in_flight = false
      for _, cb in ipairs(c.pending) do
        pcall(cb, c.items or {})
      end
      c.pending = {}
    end
    if spec.api then
      local has_fs = spec.user ~= nil or spec.project ~= nil
      api_fetch(spec, function(entries)
        if entries == nil then
          -- api 失败（exec 出错/非零退出/非法 JSON/缺 data）：告警一次；
          -- 配了 fs 目录时回退目录扫描（fs 也失败则维持旧列表/{}）
          warn_api_failure(tool, has_fs)
          if has_fs then
            local ok, fs_entries = pcall(fs_list, spec, vim.fn.getcwd())
            entries = ok and fs_entries or nil
          end
        end
        finish(entries)
      end)
    else
      -- fs 扫描小且同步，直接出结果（整体 pcall，出错降级为失败刷新）
      local ok, entries = pcall(fs_list, spec, vim.fn.getcwd())
      finish(ok and entries or nil)
    end
  end
end

--- 预热当前工具的缓存（弹窗打开时调用；仅在无缓存/已过期且未在拉取时触发）
function M.warm()
  local tool = config.current_tool()
  local spec = M.spec(tool)
  if not spec then
    return
  end
  local c = cache[cache_key(tool, spec)]
  if c and (c.in_flight or (c.items and os.time() - c.time < ttl())) then
    return
  end
  M.list(tool, function() end)
end

--- 测试注入：清空全部缓存与一次性告警状态（与 delivery._reset 同款约定）
function M._reset()
  cache = {}
  warned = {}
end

return M
