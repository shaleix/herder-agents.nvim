---@mod herder-agents.visible_files 数据层：agent pane 可见视口 → 真实文件候选
--
-- 提取逻辑忠实移植自 termscope（Python）：清理行前缀 → token / 引号 / 整行
-- span → 对 pane cwd / 仓库根 / home 解析 → 只收录磁盘上真实存在的常规文件
-- （目录不是候选），保留 `file:line[:col]` 位置。本模块不做任何 UI。

local M = {}

-- 诊断/版本标记：:AIVisibleFiles! 的日志里会打印，便于确认运行的是哪一版模块
M.VERSION = "visible-files/2"
-- 最近一次 repo_files 的数据源（诊断用）：fd / fdfind / git ls-files / none / skipped ($HOME)
M.last_repo_source = nil

local utils = require("herder-agents.utils")

local MAX_REPO_FILES = 5000 -- 索引行数上限（超大仓库控制扫描与 picker 启动开销）
local REPO_SCAN_TIMEOUT_MS = 5000 -- 索引扫描超时（utils.exec opts.timeout，毫秒）

-- ---------------------------------------------------------------------------
-- 基础路径工具
-- ---------------------------------------------------------------------------

--- 绝对路径归一：fnamemodify :p 展开后再去掉尾部 `/`（根目录 "/" 保留）
local function abspath(p)
  local abs = vim.fn.fnamemodify(p, ":p")
  abs = abs:gsub("/+$", "")
  if abs == "" then
    return "/"
  end
  return abs
end

local function home_dir()
  return abspath("~")
end

--- 是否为磁盘上真实存在的常规文件（目录 / 设备等都不是候选）
local function is_file(path)
  local ok, st = pcall(vim.uv.fs_stat, path)
  return ok and st ~= nil and st.type == "file"
end

-- ---------------------------------------------------------------------------
-- 文本清理
-- ---------------------------------------------------------------------------

-- OSC 序列：ESC ] ... 以 BEL（\a）或 ST（ESC \）终止（termscope ANSI_RE 两趟拆分）
local ANSI_OSC_BEL = "\27%][^\7]*\7"
local ANSI_OSC_ST = "\27%][^\7]*\27\\"
-- CSI 序列：ESC [ 参数字节 终止字节（termscope ANSI_CSI_RE）
local ANSI_CSI = "\27%[[0-?]*[ -/]*[@-~]"

--- 剥离 ANSI 转义（OSC BEL/ST 两趟 + CSI 一趟）
function M.strip_ansi(text)
  text = text:gsub(ANSI_OSC_BEL, "")
  text = text:gsub(ANSI_OSC_ST, "")
  text = text:gsub(ANSI_CSI, "")
  return text
end

-- pane 边框装饰（herdr pane 边界的 ┃ / │ 竖线）。按完整字面序列匹配、
-- 不放进字节 class —— Lua 的 class 按字节匹配，多字节字符放进类里会误吃
-- 其他 UTF-8 字符（如 •）的首字节
local BORDER_LEAD_A = "^%s*┃%s*(.*)$"
local BORDER_LEAD_B = "^%s*│%s*(.*)$"

--- 剥离一行可见文本的 pane 边框装饰 → 列表前缀（- * + > • / 1. / 1)）→
--- 包裹引号/反引号 → 尾部标点（termscope clean_visible_line + 边框剥除）
function M.clean_visible_line(line)
  local s = line:match(BORDER_LEAD_A) or line:match(BORDER_LEAD_B) or line
  s = s:gsub("%s*┃%s*$", ""):gsub("%s*│%s*$", "")
  s = vim.trim(s)
  -- `•` 是多字节字符，不能放进字节 class（会误吃其他 UTF-8 字符的首字节），
  -- 按字面序列单独匹配
  s = s:gsub("^[-*+>]+%s*", "")
  s = s:gsub("^•+%s*", "")
  s = s:gsub("^%d+[.)]%s*", "")
  s = vim.trim(s)
  s = s:gsub("^[`'\"]+", ""):gsub("[`'\"]+$", "")
  s = vim.trim(s)
  s = s:gsub("[.,;:]+$", "")
  return vim.trim(s)
end

-- ---------------------------------------------------------------------------
-- 捕获 / 搜索根 / 仓库索引
-- ---------------------------------------------------------------------------

--- 读取当前 pane 的可见视口（只取屏幕，不翻 scrollback）；非零退出回 nil
function M.capture(pane_id)
  local r = utils.exec(
    { "herdr", "pane", "read", pane_id, "--source", "visible", "--format", "text" },
    { timeout = 5000 }
  )
  if r.code ~= 0 then
    return nil
  end
  return r.stdout
end

--- 搜索根：cwd 所在 git 仓库根（git rev-parse --show-toplevel），回落 cwd
function M.search_root(cwd)
  local pane = abspath(cwd)
  local r = utils.exec({ "git", "-C", pane, "rev-parse", "--show-toplevel" }, { timeout = 5000 })
  if r.code == 0 then
    local p = vim.trim(r.stdout)
    if p ~= "" and vim.fn.isdirectory(p) == 1 then
      return abspath(p)
    end
  end
  return pane
end

--- 仓库文件索引（root 相对路径数组）：fd/fdfind 优先（文件+目录、含隐藏、
--- follow、排除 .git），都没有时回退 git ls-files；5s 超时、5000 行上限；
--- 根目录是 $HOME 时跳过索引（termscope 同款守卫，太大）
function M.repo_files(root)
  root = abspath(root)
  M.last_repo_source = "none"
  if root == home_dir() then
    M.last_repo_source = "skipped ($HOME)"
    return {}
  end
  local fd = nil
  if vim.fn.executable("fd") == 1 then
    fd = "fd"
  elseif vim.fn.executable("fdfind") == 1 then
    fd = "fdfind"
  end
  local function collect(stdout)
    local lines = {}
    for ln in (stdout or ""):gmatch("[^\r\n]+") do
      if ln ~= "" then
        table.insert(lines, ln)
        if #lines >= MAX_REPO_FILES then
          break
        end
      end
    end
    return lines
  end
  if fd then
    local r = utils.exec(
      { fd, "--type", "f", "--type", "d", "--hidden", "--follow", "--exclude", ".git", "." },
      { cwd = root, timeout = REPO_SCAN_TIMEOUT_MS }
    )
    if r.code == 0 then
      M.last_repo_source = fd
      return collect(r.stdout)
    end
  end
  -- fd 缺失或失败：回退 git ls-files（也覆盖非 git 目录下返回空）
  M.last_repo_source = "git ls-files"
  local r = utils.exec({ "git", "-C", root, "ls-files" }, { timeout = REPO_SCAN_TIMEOUT_MS })
  if r.code ~= 0 then
    M.last_repo_source = "none"
    return {}
  end
  return collect(r.stdout)
end

--- 诊断辅助：把文本写入临时文件（逐行），返回路径；供 :AIVisibleFiles! 或
--- 零候选自动诊断保留现场
function M.dump_text(text, label)
  local path = vim.fn.tempname() .. "." .. (label or "dump") .. ".txt"
  vim.fn.writefile(vim.split(text or "", "\n", { plain = true }), path)
  return path
end

-- ---------------------------------------------------------------------------
-- 候选提取（termscope extract_visible_candidates 移植）
-- ---------------------------------------------------------------------------

-- 路径 token 终止字符集（含这些字符的路径仍可能以整行 / 引号 span 命中）
local TOKEN_PATTERN = "[^%s`'\"<>|()%[%]{},;=]+"
local TOKEN_FULL = "^" .. TOKEN_PATTERN .. "$"
-- 引号 span：`...' / '...' / "..."（引号种类可不成对）
local QUOTED_PATTERN = "[`'\"]([^`'\"]+)[`'\"]"
-- 只剩 home/root/dot 标记的 token（如剥掉位置后的 "~"）以及 URL 全部忽略
local BARE_MARKERS = {
  ["~"] = true,
  ["~/"] = true,
  ["/"] = true,
  ["."] = true,
  ["./"] = true,
  [".."] = true,
  ["../"] = true,
}

--- 拆 `path:line[:col]` 后缀（termscope _split_line_suffix，但保留 col ——
--- Python 版会丢弃）：依次尝试 p:l:c → p:l（含尾冒号）→ 剥尾部 [:.]
local function split_line_suffix(token)
  token = (token:gsub("[.,;!?]+$", ""))
  local p, l, c = token:match("^(.+):(%d+):(%d+):?$")
  if p then
    return p, tonumber(l), tonumber(c)
  end
  p, l = token:match("^(.+):(%d+):?$")
  if p then
    return p, tonumber(l), nil
  end
  return (token:gsub("[:.]+$", "")), nil, nil
end

--- 可见文本 → 有序候选数组（display 串：path / path:line / path:line:col）。
--- screen_text 是已 strip_ansi 的视口文本；repo_paths 是 root 相对路径
--- （repo_files 的输出）；search_root / pane_path 为绝对目录。
--- 判定规则（termscope）：带 "/" 的 token 依次对 pane cwd / 仓库根解析；
--- 裸名必须有扩展名或独立出现（整行 / 引号 span），带行号或独立时还可命中
--- 仓库内唯一的 basename（含 .md 回退）；只收录真实存在的常规文件。
function M.extract_visible_candidates(screen_text, repo_paths, search_root, pane_path, opts)
  local log = opts and opts.log or nil
  local root = abspath(search_root)
  local pane = abspath(pane_path)

  -- by_basename：basename → root 相对路径列表（唯一命中才用于裸名解析）
  local by_basename = {}
  for _, p in ipairs(repo_paths or {}) do
    local clean = p:gsub("/+$", "")
    local base = clean:match("([^/]+)$")
    if base and base ~= "" then
      by_basename[base] = by_basename[base] or {}
      table.insert(by_basename[base], clean)
    end
  end

  local display_pos = {} -- display 串 → 最小出现位置（外观序）

  local function display_for(abs)
    if abs:sub(1, #root + 1) == root .. "/" then
      return abs:sub(#root + 2) -- root 内显示相对路径，picker 解析无歧义
    end
    return abs -- root 外显示绝对路径（不做 ~/ 缩写）
  end

  local function resolve(base, standalone, has_line)
    if log then
      log(("    resolve base=%q standalone=%s has_line=%s"):format(base, tostring(standalone), tostring(has_line)))
    end
    if BARE_MARKERS[base] or base:find("://", 1, true) then
      if log then
        log("      ignore: bare marker or URL")
      end
      return nil
    end
    local bases = {}
    if base:sub(1, 1) == "~" or base:sub(1, 1) == "/" then
      bases[1] = vim.fn.expand(base)
    elseif base:sub(1, 3) == "./" or base:sub(1, 4) == "../" then
      bases[1] = pane .. "/" .. base
    elseif base:find("/", 1, true) then
      bases[1] = pane .. "/" .. base
      bases[2] = root .. "/" .. base
    else
      -- termscope 的 base.strip(".")：剥掉首尾点后再判扩展名
      local stripped = base:gsub("^%.+", ""):gsub("%.+$", "")
      local has_ext = stripped:find(".", 1, true) ~= nil
      if not (has_ext or standalone) then
        if log then
          log("      ignore: bare name without extension / not standalone")
        end
        return nil
      end
      local names = has_ext and { base } or { base, base .. ".md" }
      for _, d in ipairs({ pane, root }) do
        for _, n in ipairs(names) do
          table.insert(bases, d .. "/" .. n)
        end
      end
      -- 带行号或独立出现：可命中仓库内唯一的 basename
      if has_line or standalone then
        for _, n in ipairs(names) do
          local hits = by_basename[n]
          if hits and #hits == 1 then
            table.insert(bases, root .. "/" .. hits[1])
          end
        end
      end
    end
    for _, candidate in ipairs(bases) do
      local abs = abspath(candidate)
      if log then
        local ok, st = pcall(vim.uv.fs_stat, abs)
        log(("      try %s [%s]"):format(abs, (ok and st and st.type) or "missing"))
      end
      -- 仅常规文件是候选（termscope 经 fd 目录索引也放行目录，这里按需求收紧）
      if is_file(abs) then
        return display_for(abs)
      end
    end
    return nil
  end

  local function consider(token, pos, standalone)
    token = vim.trim(token)
    -- agent/附件提及语法：@path / @path:line（插件自身的 Relate file 也是 @path）
    local stripped = (token:gsub("^@+", ""))
    if log and stripped ~= token then
      log(("  mention @ stripped: %q -> %q"):format(token, stripped))
    end
    token = stripped
    local base, line, col = split_line_suffix(token)
    if log then
      log(
        ("  token %q -> base=%q line=%s col=%s standalone=%s"):format(
          token,
          base,
          tostring(line),
          tostring(col),
          tostring(standalone)
        )
      )
    end
    if base == "" then
      return
    end
    local display = resolve(base, standalone, line ~= nil)
    if display == nil then
      if log then
        log("    => miss")
      end
      return
    end
    if line then
      display = display .. ":" .. line
      if col then
        display = display .. ":" .. col
      end
    end
    local prev = display_pos[display]
    if prev == nil or pos < prev then
      display_pos[display] = pos
    end
    if log then
      log("    => HIT " .. display)
    end
  end

  local lines = vim.split(screen_text, "\n", { plain = true })
  local bare_lines, widths = {}, {}
  -- 正文换行宽度：排除末尾 2 行 TUI 状态/页脚（它们通常按整屏宽度画，比正文更宽）
  local body_last = #lines
  if body_last > 3 then
    body_last = body_last - 2
  end
  local maxw = 0
  for i, raw in ipairs(lines) do
    -- 先剥 pane 边框再 tokenize：路径紧贴边框时 token 不会把 ┃/│ 吃进去
    local bare = raw:gsub("^%s*┃%s*", ""):gsub("^%s*│%s*", ""):gsub("%s*┃%s*$", ""):gsub("%s*│%s*$", "")
    bare_lines[i] = bare
    local w = vim.fn.strdisplaywidth(vim.trim(bare))
    widths[i] = w
    if i <= body_last and w > maxw then
      maxw = w
    end
  end

  local function process(text, line_base)
    local spans = {}
    local cleaned = M.clean_visible_line(text)
    if log then
      log(("line %d: cleaned=%q"):format(math.floor(line_base / 100000) + 1, cleaned))
    end
    if cleaned ~= "" then
      spans[cleaned] = true
    end
    for span in text:gmatch(QUOTED_PATTERN) do
      span = vim.trim(span)
      if span ~= "" then
        spans[span] = true
      end
    end
    for token in text:gmatch(TOKEN_PATTERN) do
      -- 位置取 token 首次出现处（与 spec 一致；重复 token 共享同一位置）
      consider(token, line_base + (text:find(token, 1, true) or 1), spans[token] == true)
    end
    -- 整行 / 引号 span 可含空格路径：只有非单一 token 时才参与
    for span in pairs(spans) do
      if span:match(TOKEN_FULL) == nil then
        local at = text:find(span, 1, true)
        consider(span, line_base + (at or 0), true)
      end
    end
  end

  for i, bare in ipairs(bare_lines) do
    process(bare, (i - 1) * 100000)
    -- 终端按视口宽度硬换行：上一行接近最大行宽时，尝试与下一行拼接再扫描一次
    -- （去掉下一行的缩进；路径被拆成 "lua/" + "herder-agents/..." 时靠这步命中）。
    -- 拼接产生的误报由 is_file 存在性校验过滤。
    if maxw >= 40 and i < #bare_lines and widths[i] >= maxw - 2 then
      local next_line = bare_lines[i + 1]:gsub("^%s+", "")
      if next_line ~= "" then
        if log then
          log(("line %d: try wrapped join with line %d"):format(i, i + 1))
        end
        process(bare .. next_line, (i - 1) * 100000)
      end
    end
  end

  local out = {}
  for display, pos in pairs(display_pos) do
    table.insert(out, { display = display, pos = pos })
  end
  table.sort(out, function(a, b)
    if a.pos ~= b.pos then
      return a.pos < b.pos
    end
    return a.display:lower() < b.display:lower()
  end)
  local result = {}
  for _, e in ipairs(out) do
    table.insert(result, e.display)
  end
  if log then
    log(("result: %d candidate(s)"):format(#result))
    for i, c in ipairs(result) do
      log(("  [%d] %s"):format(i, c))
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- 选中项解析与打开（utils.pick 回退通道用；fzf-lua files 走自带 file_edit）
-- ---------------------------------------------------------------------------

--- 解析选中串 → { path, line?, col? }；支持 `p:l:c` / `p:l`（含尾冒号）与
--- fzf 的 `p-l-` 上下文格式；先剥引号/反引号与首尾空白，再剥尾部标点
function M.parse_target(text)
  local t = tostring(text or "")
  t = t:match("^[^\n]*") or "" -- 只取首行
  t = (t:gsub("\r+$", ""))
  t = vim.trim(t)
  t = t:gsub("^[`'\"]+", ""):gsub("[`'\"]+$", "")
  t = vim.trim(t)
  -- 附件/agent 提及语法：@path:line
  t = (t:gsub("^@+", ""))
  t = (t:gsub("[.,;:]+$", ""))
  t = vim.trim(t)
  if t == "" then
    return { path = "" }
  end
  local p, l, c = t:match("^(.+):(%d+):(%d+):?$")
  if p then
    return { path = p, line = tonumber(l), col = tonumber(c) }
  end
  p, l = t:match("^(.+):(%d+):?$")
  if p then
    return { path = p, line = tonumber(l) }
  end
  p, l = t:match("^(.+)-(%d+)-$")
  if p then
    return { path = p, line = tonumber(l) }
  end
  return { path = t }
end

--- 文本路径 → 磁盘上真实存在的常规文件绝对路径；依次对 ~ 展开、绝对路径、
--- pane cwd 相对、仓库根相对解析；目录不是候选
function M.resolve_existing_path(path_text, pane_path, search_root)
  if path_text == nil or path_text == "" then
    return nil
  end
  local pane = abspath(pane_path)
  local root = abspath(search_root)
  local candidates = {}
  if path_text == "~" or path_text:sub(1, 2) == "~/" then
    candidates[1] = home_dir() .. path_text:sub(2)
  elseif path_text:sub(1, 1) == "/" then
    candidates[1] = path_text
  else
    candidates[1] = pane .. "/" .. path_text
    candidates[2] = root .. "/" .. path_text
  end
  for _, c in ipairs(candidates) do
    local abs = abspath(c)
    if is_file(abs) then
      return abs
    end
  end
  return nil
end

--- 在当前窗口打开选中项并跳到 line[:col]；解析/解析失败时 warn 并返回
function M.open_target(entry, pane_path, search_root)
  local target = M.parse_target(entry)
  if target.path == "" then
    utils.warn("Visible files: cannot open selection without a path")
    return
  end
  local abs = M.resolve_existing_path(target.path, pane_path, search_root)
  if abs == nil then
    utils.warn("Visible files: not found on disk: " .. target.path)
    return
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(abs))
  if not ok then
    utils.warn("Visible files: cannot open " .. abs .. ": " .. tostring(err))
    return
  end
  if target.line and target.line > 0 then
    local col = math.max(0, (target.col or 1) - 1)
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, col })
  end
end

return M
