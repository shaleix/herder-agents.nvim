-- prompt 文件附件的会话状态（内存态，随 Neovim 生命周期）
-- 文件树（输入弹窗顶部）与提交时的 "Relate file:" 附件块都取材于此；
-- 外部（如 fzf-lua 文件选择器的 ctrl-h）也可调用 current_session():add_files()
local utils = require("herder-agents.utils")

local M = {}

local Session = {}

local function create(session_name)
  local s = {
    name = session_name,
    added = {}, -- 可编辑上下文
    readonly = {}, -- 只读上下文
  }
  setmetatable(s, { __index = Session })
  return s
end

---@param cmd string
function Session:send(cmd)
  local prompt = ""

  -- Add information about added files
  if #self.added > 0 then
    prompt = prompt .. "Modify files:\n"
    for _, file in ipairs(self.added) do
      prompt = prompt .. "- @" .. file .. "\n"
    end
    prompt = prompt .. "\n"
  end

  -- Add information about readonly files
  if #self.readonly > 0 then
    prompt = prompt .. "Read files:\n"
    for _, file in ipairs(self.readonly) do
      prompt = prompt .. "- @" .. file .. "\n"
    end
    prompt = prompt .. "\n"
  end

  -- Add the command content
  prompt = prompt .. cmd

  require("herder-agents.ui.chat").send_tool_prompt(vim.g.ai_tool, prompt)
end

function Session:clear_files()
  self.added = {}
  self.readonly = {}
end

function Session:list_files()
  local files = {
    added = {},
    readonly = {},
  }
  for _, file in ipairs(self.added) do
    table.insert(files.added, file)
  end
  for _, file in ipairs(self.readonly) do
    table.insert(files.readonly, file)
  end
  return files
end

---@param file_paths string[]
function Session:add_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    local relative_path = utils.get_relative_path(file_path)

    -- Check if file is already in readonly, move it to added
    for i, readonly_file in ipairs(self.readonly) do
      local readonly_relative = utils.get_relative_path(readonly_file)

      if readonly_relative == relative_path then
        table.remove(self.readonly, i)
        break
      end
    end

    -- Add to added table if not already there
    local found = false
    for _, added_file in ipairs(self.added) do
      local added_relative = utils.get_relative_path(added_file)

      if added_relative == relative_path then
        found = true
        break
      end
    end

    if not found then
      table.insert(self.added, relative_path)
    end
  end
end

---@param file_paths string[]
function Session:read_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    local relative_path = utils.get_relative_path(file_path)

    -- Check if file is already in added, remove it from added if found
    for i, added_file in ipairs(self.added) do
      local added_relative = utils.get_relative_path(added_file)
      if added_relative == relative_path then
        table.remove(self.added, i)
        break
      end
    end

    -- Add to readonly if not already there
    local found = false
    for _, readonly_file in ipairs(self.readonly) do
      local readonly_relative = utils.get_relative_path(readonly_file)
      if readonly_relative == relative_path then
        found = true
        break
      end
    end

    if not found then
      table.insert(self.readonly, relative_path)
    end
  end
end

function Session:drop_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    -- Remove from added table
    for i, added_file in ipairs(self.added) do
      if added_file == file_path then
        table.remove(self.added, i)
        break
      end
    end

    -- Remove from readonly table
    for i, readonly_file in ipairs(self.readonly) do
      if readonly_file == file_path then
        table.remove(self.readonly, i)
        break
      end
    end
  end
end

local current = create()

M.current_session = function()
  return current
end

return M
