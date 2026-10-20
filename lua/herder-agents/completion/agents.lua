-- blink.cmp source：herdr agent 提及（herdr:<pane_id>）补全（thin 适配层，
-- 数据获取收口在 agents.lua）。
--
-- 提及是纯文本：把 pane_id (workspace:kind) 插进 prompt（输入的 "herdr:" 留在
-- buffer），提交/投递行为完全不变（无 token 解析/路由）。候选即 `herdr agent list`
-- 返回的当前 herdr 会话 agent（跨 workspace），含当前 agent 本身（据输入
-- buffer 的 vim.b.pane_id 精确匹配，补全路径零额外 CLI）。
--
-- agents.lua 内部完成 TTL 缓存与异步管理（5s，stale-while-refresh，失败静默
-- 降级），本层只做 blink 协议适配：
--   - 触发字符 ":"：仅当当前空白分隔 token 以字面 "herdr:" 开头才出候选
--     （blink keyword 不含 ":"，从 keyword 起点回看 —— 同 completion/skills.lua）
--   - label = pane_id；insertText = pane_id + " (workspace:kind)"（与候选显示
--     完全一致，选中后原样写进 prompt）；显式 insertText 让 blink 不从
--     filterText 猜编辑范围；(workspace:kind) 同时放 labelDetails.detail ——
--     blink 默认 label 组件渲染 ctx.label .. ctx.label_detail（detail 字段默认
--     菜单不渲染）；filterText 附带 workspace/kind/name/终端标题/cwd 供模糊过滤
--   - 排序：当前 agent score_offset 最高，其次当前 tab 的 agent，其余交给
--     blink 模糊排序
local M = {}

local agents = require("herder-agents.agents")

local kind_text = 1 -- LSP CompletionItemKind.Text（blink.cmp.types 加载失败时的兜底值）
do
  local ok, types = pcall(require, "blink.cmp.types")
  if ok and types and types.CompletionItemKind then
    kind_text = types.CompletionItemKind.Text
  end
end

-- new(opts) 写入的 source opts（保留兼容；ttl 由 agents.lua 自管）
M.opts = nil

-- 拼接 filterText 片段：跳过 nil/空串
local function join_filter(parts)
  local out = {}
  for _, p in ipairs(parts) do
    if p and p ~= "" then
      table.insert(out, p)
    end
  end
  return table.concat(out, " ")
end

-- 由 agents.list 回调的规范化条目构建 blink items
---@param entries table 规范化条目 { {pane_id, kind, status, name, title, cwd, tab_id, workspace_id, workspace}, ... }
---@param current string|nil 输入 buffer 绑定的 pane_id（精确匹配者标记 current）
---@param current_tab string|nil 当前 tab（current 条目的 tab_id，回落 $HERDR_TAB_ID）
---@return table blink.cmp CompletionItem[]
local function build_items(entries, current, current_tab)
  local items = {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and e.pane_id then
      local is_current = current ~= nil and e.pane_id == current
      local same_tab = current_tab ~= nil and e.tab_id ~= nil and e.tab_id == current_tab
      local kind = e.kind or ""
      local status = e.status or ""
      local ws = e.workspace or "" -- 数据层已回落 workspace_id，此处再兜底为 ""
      -- 菜单角标：workspace:kind 随 label 拼接展示。单边缺失时优雅降级
      -- （绝不出 "( :kind)"/"(:kind)"），双边皆空不挂角标
      local tag
      if ws ~= "" and kind ~= "" then
        tag = " (" .. ws .. ":" .. kind .. ")"
      elseif kind ~= "" then
        tag = " (" .. kind .. ")"
      elseif ws ~= "" then
        tag = " (" .. ws .. ")"
      end
      -- detail 行只放 status（kind 已进 labelDetails）；空 status 且非当前 → 空
      local detail = status
      if is_current then
        detail = (status ~= "" and (status .. " · current")) or "current"
      end
      -- documentation 汇总全部寻址上下文（workspace 名 + id、name/终端标题/cwd/tab 按有则显示）
      local doc_lines = {
        ("- pane: `%s`"):format(e.pane_id),
        ("- kind/status: %s · %s"):format(kind, status),
      }
      if ws ~= "" then
        table.insert(doc_lines, ("- workspace: %s"):format(ws))
      end
      if e.workspace_id and e.workspace_id ~= "" and e.workspace_id ~= ws then
        table.insert(doc_lines, ("- workspace id: %s"):format(e.workspace_id))
      end
      if e.name and e.name ~= "" then
        table.insert(doc_lines, ("- name: %s"):format(e.name))
      end
      if e.title and e.title ~= "" then
        table.insert(doc_lines, ("- title: %s"):format(e.title))
      end
      if e.cwd and e.cwd ~= "" then
        table.insert(doc_lines, ("- cwd: %s"):format(e.cwd))
      end
      if e.tab_id and e.tab_id ~= "" then
        table.insert(doc_lines, ("- tab: %s"):format(e.tab_id))
      end
      -- label = pane_id；insertText 追加与 labelDetails 相同的 (workspace:kind)
      -- 注记（不含触发字符；无尾随空格 —— 提及是纯文本）
      local insert = tag and (e.pane_id .. tag) or e.pane_id
      table.insert(items, {
        label = e.pane_id,
        insertText = insert,
        kind = kind_text,
        labelDetails = tag and { detail = tag } or nil,
        detail = detail,
        filterText = join_filter({ e.pane_id, ws, kind, e.name or "", e.title or "", e.cwd or "" }),
        documentation = {
          kind = "markdown",
          value = table.concat(doc_lines, "\n"),
        },
        score_offset = is_current and 10 or (same_tab and 5 or 0),
      })
    end
  end
  return items
end

-- ---------------------------------------------------------------------------
-- blink.cmp source 接口（module = "herder-agents.completion.agents"）
-- ---------------------------------------------------------------------------

function M.new(opts)
  local self = setmetatable({}, { __index = M })
  self.opts = opts or {}
  return self
end

function M.get_trigger_characters()
  return { ":" }
end

function M:get_completions(ctx, callback)
  -- 只在当前空白分隔 token 以字面 "herdr:" 开头时补全：keyword 不含 ":"（blink
  -- v1.10.2 keyword 范围排除触发字符），从 keyword 起点回看行首前缀（大小写
  -- 敏感，宽松匹配 —— "xherdr:" 也命中；pane_id 自带的 ":" 不中断候选）。
  -- 兼容 blink.cmp v1（ctx.keyword / ctx.cursor）与 v2（ctx:get_keyword() / ctx.pos）
  local line = ctx.line or ""
  local keyword = ctx.keyword
  if keyword == nil and type(ctx.get_keyword) == "function" then
    keyword = ctx:get_keyword()
  end
  keyword = keyword or ""
  local col = ctx.pos and ctx.pos[2] or (ctx.cursor and ctx.cursor[2]) or 0
  local i = col - #keyword
  local before = line:sub(1, i)
  -- token 以 "herdr:" 开头才出候选（pane_id 自带 ":" 不中断；宽松匹配）
  if not before:match("herdr:[^%s]*$") then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
    return
  end

  local buf = ctx.bufnr or vim.api.nvim_get_current_buf()
  local current = agents.current_pane_id(buf)
  -- 每次调用按 agents.list 的当前列表重建 items（无独立 items 缓存）；
  -- 无缓存的挂起回调也经 agents.list 统一 flush
  agents.list(function(entries)
    -- 当前 tab：优先取 current 条目所在 tab，无绑定时回落环境变量
    -- （同 tab 加分依据；current 加分不受影响）
    local current_tab = vim.env.HERDR_TAB_ID
    if current then
      for _, e in ipairs(type(entries) == "table" and entries or {}) do
        if type(e) == "table" and e.pane_id == current and e.tab_id then
          current_tab = e.tab_id
          break
        end
      end
    end
    local items = build_items(entries, current, current_tab)
    pcall(callback, {
      items = vim.deepcopy(items),
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
  end)
end

return M
