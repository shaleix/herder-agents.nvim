-- prompt 历史读写与回看（并入原历史弹窗模块 + chat 的 save_history 迁入）：
-- - JSON 文件按 cwd 路径分桶：history_file = { [path] = { { content, timestamp }, ... } }
-- - M.save：chat 弹窗提交路径追加一条（read-modify-write）
-- - M.load：全量读取，文件缺失 / 空 / JSON 损坏 → 空表（不炸）
-- - M.input_history_view（<leader>hh）：全量平铺展示，回车选中回填到输入弹窗
local M = {}
local mapOpts = { noremap = true }
local utils = require("herder-agents.utils")
local common = require("herder-agents.ui.common")
local config = require("herder-agents.config")

function M.load()
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

-- 追加一条 prompt 历史（read-modify-write；路径分桶，条目 { content, timestamp }）
function M.save(value, path)
  local history_file = config.options.history_file
  local history = {}
  local f = io.open(history_file, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
      local ok, data = pcall(vim.fn.json_decode, content)
      if ok then
        history = data
      end
    end
  end
  if not history[path] then
    history[path] = {}
  end
  table.insert(history[path], {
    content = value,
    timestamp = os.time(),
  })
  local json_str = vim.fn.json_encode(history)
  f = io.open(history_file, "w")
  if f then
    f:write(json_str)
    f:close()
  end
end

function M.input_history_view(on_select)
  on_select = on_select
    or function(content)
      -- 惰性 require：ui.chat 依赖本模块保存历史，反向直引会成环
      require("herder-agents.ui.chat").show_input_tool(config.current_tool(), content)
    end
  local history = M.load()
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
