-- blink.cmp source：opencode skills 补全（"@" 触发）。
--
-- 数据来自 `opencode api skill.list`（v2 API），异步拉取并按 ttl 缓存：
--   - 缓存新鲜：直接回缓存（blink 会就地改写 item，永远交 deepcopy）
--   - 缓存过期：先回旧列表，同时后台刷新
--   - 无缓存：回调挂起，首拉完成后统一 flush，任何失败都静默降级、绝不报错
-- label 不含前导 "@" —— 输入的 "@" 留在 buffer 里，blink 只替换 keyword 部分。
local M = {}

local utils = require("herder-agents.utils")

local kind_text = 1 -- LSP CompletionItemKind.Text（blink.cmp.types 加载失败时的兜底值）
do
  local ok, types = pcall(require, "blink.cmp.types")
  if ok and types and types.CompletionItemKind then
    kind_text = types.CompletionItemKind.Text
  end
end

-- new(opts) 写入的 source opts（当前只有 ttl）；new 之前调用 warm() 用默认值
M.opts = nil

local cache = { items = nil, time = 0, in_flight = false, pending = {} }

local function ttl()
  return (M.opts and M.opts.ttl) or 300
end

---@param data table skill.list 响应里的 data 数组
---@return table blink.cmp CompletionItem[]
local function build_items(data)
  local items = {}
  for _, skill in ipairs(type(data) == "table" and data or {}) do
    if type(skill) == "table" and skill.id then
      local desc = skill.description or ""
      table.insert(items, {
        label = skill.id, -- 不含 "@"：typed "@" 留在 buffer，blink 只替换 keyword
        kind = kind_text,
        detail = "skill: " .. desc,
        documentation = {
          kind = "markdown",
          value = ("**%s**\n\n%s\n\n`%s`"):format(skill.name or skill.id, desc, skill.path or ""),
        },
      })
    end
  end
  return items
end

-- 统一 flush 挂起中的回调（每家一份 deepcopy，包装成 blink CompletionResponse）
local function flush_pending()
  local items = cache.items or {}
  for _, cb in ipairs(cache.pending) do
    pcall(cb, {
      items = vim.deepcopy(items),
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
  end
  cache.pending = {}
end

---@param on_done fun()|nil 拉取结束（成败都算）后的回调
local function fetch(on_done)
  if cache.in_flight then
    return
  end
  cache.in_flight = true
  utils.exec_async({ "opencode", "api", "skill.list" }, function(r)
    if r.code == 0 and r.stdout ~= "" then
      local ok, decoded = pcall(vim.json.decode, r.stdout)
      if ok and type(decoded) == "table" and type(decoded.data) == "table" then
        cache.items = build_items(decoded.data)
        cache.time = os.time()
      end
    end
    -- 失败也 flush（回 {} 或旧列表）：补全不报错、不阻塞
    cache.in_flight = false
    flush_pending()
    if on_done then
      on_done()
    end
  end)
end

--- 预热 skill 缓存（弹窗打开时调用；无缓存 / 已过期才拉取）
function M.warm()
  if not cache.items or os.time() - cache.time >= ttl() then
    fetch(function() end)
  end
end

-- ---------------------------------------------------------------------------
-- blink.cmp source 接口（module = "herder-agents.completion.skills"）
-- ---------------------------------------------------------------------------

function M.new(opts)
  local self = setmetatable({}, { __index = M })
  self.opts = opts or {}
  M.opts = self.opts -- 模块级共享：warm() 由此读 ttl
  return self
end

function M.get_trigger_characters()
  return { "@" }
end

function M:get_completions(ctx, callback)
  -- 只在紧邻 "@" 之后补全：keyword 前一个字符（行首时无前字符）。
  -- 兼容 blink.cmp v1（ctx.keyword / ctx.cursor）与 v2（ctx:get_keyword() / ctx.pos）
  local line = ctx.line or ""
  local keyword = ctx.keyword
  if keyword == nil and type(ctx.get_keyword) == "function" then
    keyword = ctx:get_keyword()
  end
  keyword = keyword or ""
  local col = ctx.pos and ctx.pos[2] or (ctx.cursor and ctx.cursor[2]) or 0
  local i = col - #keyword
  local trigger = i >= 1 and line:sub(i, i) or ""
  if trigger ~= "@" then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
    return
  end

  if cache.items then
    callback({
      items = vim.deepcopy(cache.items),
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
    if os.time() - cache.time >= ttl() then
      fetch(function() end) -- 过期：先回旧列表，后台刷新
    end
    return
  end

  -- 首拉未完成：挂起回调，fetch 完成后 flush
  table.insert(cache.pending, callback)
  if not cache.in_flight then
    fetch()
  end
end

return M
