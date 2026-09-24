-- 工具分发注册表
--
-- 两类后端：
-- - herdr 后端：CLI 工具跑在 herdr pane 里，由 ui/chat 驱动（config.tools 注册）
-- - 外部后端：register_tool() 注册（如 agentic 插件），提供自己的 toggle/input 等实现
--
-- 当前工具状态存 vim.g.ai_tool（外部脚本可读写），未注册时回落到 default_tool
local M = {}

local chat = require("herder-agents.ui.chat")
local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local order = {} -- 切换器顺序（herdr 工具在前，外部后端按注册顺序追加）
local dispatch = {}

local function register(name, def, at_front)
  if dispatch[name] then
    return
  end
  dispatch[name] = def
  if at_front then
    table.insert(order, 1, name)
  else
    table.insert(order, name)
  end
end

-- herdr pane CLI 工具（含 opencode）由注册表驱动；
-- 新增一个 CLI 工具只需在 config.tools 加一项
function M.register_herdr_tools()
  for _, name in ipairs(chat.herdr_tool_names()) do
    register(name, {
      herdr = true,
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
    })
  end
end

-- 注册外部（非 herdr）工具后端。def 各字段均为函数：
--   toggle() input([content]) history() interrupt() new()
--   select_session?() switch_provider?() read_buffer?() add_buffer?()
-- read_buffer / add_buffer 缺省回落到会话文件附件（提交时附加 "Relate file:" 块）
function M.register_tool(name, def)
  local fallback = {
    read_buffer = function()
      M.api.read_current_buffer()
    end,
    add_buffer = function()
      M.api.add_current_buffer()
    end,
  }
  register(name, vim.tbl_extend("keep", def, fallback))
end

-- 文件附件 API（<leader>hr / <leader>ha 对非 herdr 后端的默认实现；
-- 兼容原 ai_tools.api 的用法：require("herder-agents").api.add_current_buffer()）
M.api = {}

function M.api.add_current_buffer()
  local sessions = require("herder-agents.sessions")
  if vim.bo.buftype == "" then
    local buffer_path = vim.fn.expand("%:p")
    sessions.current_session():add_files({ buffer_path })
  end
end

function M.api.read_current_buffer()
  local sessions = require("herder-agents.sessions")
  if vim.bo.buftype == "" then
    local buffer_path = vim.fn.expand("%:p")
    sessions.current_session():read_files({ buffer_path })
  end
end

function M.api.add_file(path)
  local sessions = require("herder-agents.sessions")
  sessions.current_session():add_files({ path })
  vim.notify("Added file: " .. path, vim.log.levels.INFO)
end

function M.api.read_file(path)
  local sessions = require("herder-agents.sessions")
  sessions.current_session():read_files({ path })
  vim.notify("Read file: " .. path, vim.log.levels.INFO)
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

function M.is_herdr_cli()
  local backend = M.backend()
  return backend ~= nil and backend.herdr == true
end

return M
