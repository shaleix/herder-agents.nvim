-- blink.cmp source：skill 补全（thin 适配层，数据获取收口在 skills.lua）。
--
-- 触发字符与数据源都按当前工具的 tools.<name>.skills 配置走（opencode "@"
-- + CLI JSON 列表；qodercli/pi "/" + 文件系统发现）。skills.list 内部完成
-- 缓存与异步管理，本层只做 blink 协议适配：
--   - 缓存新鲜：同步回列表（blink 会就地改写 item，永远交 deepcopy）
--   - 缓存过期：先回旧列表，同时后台刷新
--   - 无缓存：回调挂起，首拉完成后统一 flush，任何失败都静默降级、绝不报错
-- label 不含前导触发字符 —— 输入的字符留在 buffer 里，blink 只替换 keyword
-- 部分；pi 的斜杠命令是 /skill:<name>，label 由 skills 配置的 label_prefix 补出。
local M = {}

local config = require("herder-agents.config")
local skills = require("herder-agents.skills")

local kind_text = 1 -- LSP CompletionItemKind.Text（blink.cmp.types 加载失败时的兜底值）
do
  local ok, types = pcall(require, "blink.cmp.types")
  if ok and types and types.CompletionItemKind then
    kind_text = types.CompletionItemKind.Text
  end
end

-- new(opts) 写入的 source opts（保留兼容；ttl 现由 skills.lua 从 config 读）
M.opts = nil

-- 由 skills.list 回调的规范化条目构建 blink items（label 带 label_prefix）
---@param entries table 规范化条目 { {id, name, description, path}, ... }
---@param spec table|nil 工具的 skills 配置（label_prefix 由此读）
---@return table blink.cmp CompletionItem[]
local function build_items(entries, spec)
  local prefix = (spec and spec.label_prefix) or ""
  local items = {}
  for _, skill in ipairs(type(entries) == "table" and entries or {}) do
    if type(skill) == "table" and skill.id then
      local desc = skill.description or ""
      table.insert(items, {
        -- label 不含触发字符：typed 字符留在 buffer，blink 只替换 keyword
        label = prefix .. skill.id,
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

-- ---------------------------------------------------------------------------
-- blink.cmp source 接口（module = "herder-agents.completion.skills"）
-- ---------------------------------------------------------------------------

function M.new(opts)
  local self = setmetatable({}, { __index = M })
  self.opts = opts or {}
  return self
end

function M.get_trigger_characters()
  return skills.triggers()
end

function M:get_completions(ctx, callback)
  -- 只在紧邻触发字符之后补全：keyword 前一个字符（行首时无前字符）。
  -- 兼容 blink.cmp v1（ctx.keyword / ctx.cursor）与 v2（ctx:get_keyword() / ctx.pos）
  local line = ctx.line or ""
  local keyword = ctx.keyword
  if keyword == nil and type(ctx.get_keyword) == "function" then
    keyword = ctx:get_keyword()
  end
  keyword = keyword or ""
  local col = ctx.pos and ctx.pos[2] or (ctx.cursor and ctx.cursor[2]) or 0
  local i = col - #keyword
  local char = i >= 1 and line:sub(i, i) or ""
  local tool = config.current_tool()
  if char ~= skills.trigger(tool) then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
    return
  end

  local spec = skills.spec(tool)
  -- 每次调用按 skills.list 的当前列表现建 items（无独立 items 缓存）；
  -- 无缓存的挂起回调也经 skills.list 统一 flush
  skills.list(tool, function(entries)
    local items = build_items(entries, spec)
    pcall(callback, {
      items = vim.deepcopy(items),
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
  end)
end

return M
