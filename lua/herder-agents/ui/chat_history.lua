-- prompt 历史的快速回看（<leader>hh）：全量平铺展示，回车选中回填到输入弹窗
local M = {}
local mapOpts = { noremap = true }
local utils = require("herder-agents.utils")
local common = require("herder-agents.ui.common")
local config = require("herder-agents.config")

local function load_history()
  local f = io.open(config.options.history_file, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return {}
  end
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

function M.input_history_view(on_select)
  on_select = on_select
    or function(content)
      require("herder-agents.ui.chat").show_input_tool(vim.g.ai_tool, content)
    end
  local history = load_history()
  local cwd = vim.fn.getcwd()
  local path_history = history[cwd] or {}

  if #path_history == 0 then
    utils.warn("No history found for current directory")
    return
  end

  local Popup = require("nui.popup")
  local NuiText = require("nui.text")
  local popup = Popup({
    relative = "editor",
    position = "50%",
    enter = true,
    size = { width = 0.6, height = 0.7 },
    border = {
      padding = {
        left = 2,
        right = 2,
        top = 1,
        bottom = 1,
      },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(" Input History ", "AiderPromptTitle"),
        top_align = "center",
        bottom = NuiText("Enter: open history entry | q: close", "AiderComment"),
        bottom_align = "right",
      },
    },
    buf_options = {
      filetype = "conf",
      buftype = "nofile",
      swapfile = false,
      undofile = false,
    },
  })
  popup:mount()

  local entry_map = {}
  local content = {}

  for i = #path_history, 1, -1 do
    local entry = path_history[i]
    local timestamp = os.date("%Y-%m-%d %H:%M:%S", entry.timestamp or 0)
    table.insert(content, "# " .. timestamp)
    local lines = vim.split(entry.content or "", "\n")
    for _, line in ipairs(lines) do
      table.insert(content, "> " .. line)
      entry_map[#content] = entry
    end
    table.insert(content, "")
  end

  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, content)
  common.dim(popup.bufnr)

  popup:map("n", "<Enter>", function()
    local line_num = vim.api.nvim_win_get_cursor(0)[1] - 1
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local current_line = lines[line_num + 1]

    if current_line:match("^> ") then
      local entry = entry_map[line_num + 1]
      if entry then
        on_select(entry.content)
        popup:unmount()
      end
    end
  end, mapOpts)

  popup:map("n", "q", function()
    popup:unmount()
  end, mapOpts)
end

return M
