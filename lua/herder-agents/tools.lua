-- herdr CLI 工具注册表与当前工具状态
--
-- 所有工具都以 CLI 命令的形式跑在 herdr pane 里，由 ui/chat 驱动
-- （config.tools 注册，新增工具只需加一项）
-- 当前工具状态存 vim.g.ai_tool（外部脚本可读写），未注册时回落到 default_tool
local M = {}

local chat = require("herder-agents.ui.chat")
local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local order = {} -- 切换器顺序（config.tool_order）
local dispatch = {}

local function register(name, def)
  if dispatch[name] then
    return
  end
  dispatch[name] = def
  table.insert(order, name)
end

function M.register_herdr_tools()
  for _, name in ipairs(chat.herdr_tool_names()) do
    register(name, {
      toggle = function()
        chat.toggle_tool(name)
      end,
      input = function(content)
        chat.show_input_tool(name, content)
      end,
      history = function()
        require("herder-agents.ui.chat_history").input_history_view(function(content)
          chat.show_input_tool(name, content)
        end)
      end,
      interrupt = function()
        chat.interrupt_tool(name)
      end,
      new = function()
        chat.new_tool_session(name)
      end,
      switch_mode = function()
        chat.switch_tool_mode(name)
      end,
    })
  end
end

-- 切换器（<leader>ht / :AISwitch）的候选列表
function M.names()
  return vim.list_extend({}, order)
end

function M.has(name)
  return dispatch[name] ~= nil
end

---@return string
function M.current_name()
  return vim.g.ai_tool or config.options.default_tool
end

---@param name string
---@return boolean ok 校验失败（未注册）时通知并返回 false
function M.set(name)
  if not M.has(name) then
    utils.err("Unknown AI tool: " .. name)
    return false
  end
  vim.g.ai_tool = name
  vim.notify("AI tool switched to: " .. name, vim.log.levels.INFO)
  return true
end

-- 当前工具的后端定义（未注册时回落到 default_tool 的后端）
function M.backend()
  return dispatch[M.current_name()] or dispatch[config.options.default_tool]
end

return M
