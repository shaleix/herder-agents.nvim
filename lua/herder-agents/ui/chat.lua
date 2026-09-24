-- herdr pane 控制与 prompt 输入弹窗
--
-- - 工具注册表来自 config.options.tools（setup 可扩展），此处不再硬编码
-- - toggle：当前 tab 无该工具 pane 时分屏启动，已有时切换 pane zoom
-- - input：nui 弹窗草稿（顶部文件树 / 诊断插入 / Ctrl+t 符号路径），
--   提交时 bracketed paste 发送到 pane 并回车
local M = {}
local common = require("herder-agents.ui.common")
local sessions = require("herder-agents.sessions")
local utils = require("herder-agents.utils")
local config = require("herder-agents.config")

-- Prompt 输入框标题（U+EBCF 图标用字节转义，避免编辑时丢失私有区字符）
local prompt_label = "\238\175\143 Prompt"

local last_input_content = {}
local mapOpts = { noremap = true }

local function group_tree_paths(paths)
  local tree = {}
  for _, path in ipairs(paths) do
    local parts = vim.split(path, "/", { plain = true })
    local current_node = tree
    local current_path = ""
    for i, part in ipairs(parts) do
      local found = false
      for _, child in ipairs(current_node) do
        if child.name == part then
          current_node = child.children
          current_path = child.path
          found = true
          break
        end
      end
      if not found then
        local new_node = {
          type = (i == #parts and "file" or "folder"),
          name = part,
          path = current_path .. (current_path == "" and "" or "/") .. part,
        }
        if i < #parts then
          new_node.children = {}
        end
        table.insert(current_node, new_node)
        current_node = new_node.children
        current_path = new_node.path
      end
    end
  end

  local function merge_folders(node)
    if node.type == "folder" and #node.children == 1 and node.children[1].type == "folder" then
      node.name = node.name .. "/" .. node.children[1].name
      node.path = node.path .. "/" .. node.children[1].name
      node.children = node.children[1].children
      merge_folders(node)
    elseif node.type == "folder" and #node.children > 0 then
      for _, child in ipairs(node.children) do
        merge_folders(child)
      end
    end
  end

  for _, root in ipairs(tree) do
    merge_folders(root)
  end

  return tree
end

local function get_all_file_paths(tree, node)
  local paths = {}
  if node.type == "file" then
    table.insert(paths, node.path)
  elseif node:has_children() then
    local children = tree:get_nodes(node:get_id())
    for _, child in ipairs(children) do
      vim.list_extend(paths, get_all_file_paths(tree, child))
    end
  end
  return paths
end

local function save_history(value, path)
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

local function popup_input(prompt, on_submit, opts, title)
  local Popup = require("nui.popup")
  local NuiText = require("nui.text")
  local Layout = require("nui.layout")
  local allow_empty = opts.allow_empty or false
  local default_value = opts.default_value or (last_input_content[title] or "")
  local top_popup = Popup({
    position = "50%",
    size = {
      width = 80,
      height = 1,
    },
    border = {
      padding = {
        left = 1,
        right = 2,
      },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(title or "", "FloatTitle"),
        top_align = "center",
      },
    },
    buf_options = {
      filetype = "aider-fixed-content",
    },
    win_options = {
      winhighlight = "Normal:AiderInputFloatNormal,FloatBorder:AiderInputFloatBorder",
    },
  })

  local cursor_path
  local support_get_path = true
  utils.get_current_path(function(path)
    cursor_path = path
  end, function()
    support_get_path = false
  end)

  local bottom_popup = Popup({
    position = "50%",
    size = {
      width = 80,
      height = 10,
    },
    enter = true,
    border = {
      padding = {
        left = 1,
        right = 1,
        top = 0,
        bottom = 1,
      },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(" " .. prompt, "MoreMsg"),
        top_align = "left",
        bottom = NuiText("Ctrl+Enter: submit | Ctrl+t: path | Ctrl+d: diagnostics | Ctrl+x: clear files", "LineNr"),
        bottom_align = "right",
      },
    },
    buf_options = {
      filetype = "aider-input",
    },
    win_options = {
      winhighlight = "Normal:AiderInputFloatNormal,FloatBorder:AiderInputFloatBorder",
    },
  })
  local split = Popup({
    focusable = false,
    border = {
      style = { " ", " ", " ", " ", " ", "─", " ", " " },
      text = {
        bottom = NuiText(" dd: drop | o: fold | D: clear | <CR>: open", "LineNr"),
        bottom_align = "right",
      },
    },
    win_options = {
      winhighlight = "Normal:AiderInputFloatNormal,FloatBorder:LineNr",
    },
  })

  local layout = Layout(
    {
      position = "50%",
      relative = "editor",
      size = {
        width = common.clamp_popup_width(config.options.chat_size.width),
        height = config.options.chat_size.height,
      },
    },
    Layout.Box({
      Layout.Box(top_popup, { grow = 1 }),
      Layout.Box(split, { size = { height = 1 } }),
      Layout.Box(bottom_popup, { size = { height = 12 } }),
    }, { dir = "col" })
  )

  local original_winid = vim.api.nvim_get_current_win()
  -- 源缓冲区：Ctrl+d 附加诊断时的取材对象
  local original_bufnr = vim.api.nvim_get_current_buf()

  local on_input_submit = function()
    local bufnr = bottom_popup.bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local value = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")

    if value == "" and not allow_empty then
      utils.warn("Submit content is empty, skip")
      return
    end

    layout:unmount()
    on_submit(value)
    last_input_content[title] = ""

    if original_winid then
      pcall(vim.api.nvim_set_current_win, original_winid)
    end
  end
  local handle_quit = function()
    local bufnr = bottom_popup.bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    last_input_content[title] = lines
    layout:unmount()

    if original_winid then
      pcall(vim.api.nvim_set_current_win, original_winid)
    end
  end

  top_popup:map("n", "q", handle_quit, mapOpts)
  top_popup:map("n", "<Esc>", handle_quit, mapOpts)
  top_popup:map("i", "<C-q>", handle_quit, mapOpts)
  top_popup:map("n", "<C-q>", handle_quit, mapOpts)
  top_popup:map("n", "<C-s>", on_input_submit, mapOpts)
  top_popup:map("n", "<Tab>", function()
    vim.api.nvim_set_current_win(bottom_popup.winid)
  end, mapOpts)
  top_popup:map("i", "<C-s>", function()
    vim.api.nvim_input("<C-[>")
    on_input_submit()
  end, mapOpts)
  top_popup:map("n", "<C-j>", function()
    vim.api.nvim_set_current_win(bottom_popup.winid)
    vim.api.nvim_input("a")
  end, mapOpts)

  bottom_popup:map("n", "<Tab>", function()
    vim.api.nvim_set_current_win(top_popup.winid)
  end, mapOpts)
  bottom_popup:map("n", "q", handle_quit, mapOpts)
  bottom_popup:map("n", "<Esc>", handle_quit, mapOpts)
  bottom_popup:map("i", "<C-q>", handle_quit, mapOpts)
  bottom_popup:map("n", "<C-q>", handle_quit, mapOpts)
  bottom_popup:map("i", "<C-k>", function()
    vim.api.nvim_set_current_win(top_popup.winid)
    vim.api.nvim_input("<C-[>")
  end, mapOpts)
  bottom_popup:map("n", "<C-k>", function()
    vim.api.nvim_set_current_win(top_popup.winid)
  end, mapOpts)
  bottom_popup:map("n", "<C-Enter>", on_input_submit, mapOpts)
  bottom_popup:map("i", "<C-Enter>", function()
    vim.api.nvim_input("<C-[>")
    on_input_submit()
  end, mapOpts)
  bottom_popup:map("n", "<C-t>", function()
    if cursor_path then
      local line = "Target position: " .. cursor_path
      vim.api.nvim_buf_set_lines(bottom_popup.bufnr, 0, 0, false, { line })
    end
  end, mapOpts)
  bottom_popup:map("i", "<C-t>", function()
    if not support_get_path then
      utils.warn("Get path not supported")
    end
    if cursor_path then
      local line = "Target position: " .. cursor_path
      vim.api.nvim_buf_set_lines(bottom_popup.bufnr, 0, 0, false, { line })
    end
  end, mapOpts)

  -- Ctrl+d：把源缓冲区诊断作为可编辑文本行插入草稿
  local function insert_diagnostics()
    local block = require("herder-agents.context").diagnostics(original_bufnr)
    if not block then
      utils.warn("No diagnostics found")
      return
    end
    local row = vim.api.nvim_win_get_cursor(bottom_popup.winid)[1]
    vim.api.nvim_buf_set_lines(bottom_popup.bufnr, row, row, false, { "" })
    vim.api.nvim_buf_set_lines(bottom_popup.bufnr, row + 1, row + 1, false, vim.split(block, "\n", { plain = true }))
  end
  bottom_popup:map("n", "<C-d>", insert_diagnostics, mapOpts)
  bottom_popup:map("i", "<C-d>", insert_diagnostics, mapOpts)

  layout:mount()
  common.dim(bottom_popup.bufnr)

  local lines = {}
  if type(default_value) == "string" then
    for line in default_value:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end
  else
    lines = default_value
  end
  vim.api.nvim_buf_set_lines(bottom_popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_input("GA")
  return top_popup, bottom_popup, layout
end

local function setup_file_tree(popup, prompt_popup, layout, session)
  local NuiTree = require("nui.tree")
  local NuiLine = require("nui.line")
  local icons = config.options.icons

  local function build_tree_nodes(grouped_paths)
    local nodes = {}
    for _, item in ipairs(grouped_paths) do
      if item.type == "folder" and item.children then
        local children = build_tree_nodes(item.children)
        local node = NuiTree.Node({
          text = item.name,
          path = item.path,
          type = "folder",
        }, children)
        node:expand()
        table.insert(nodes, node)
      else
        table.insert(
          nodes,
          NuiTree.Node({
            text = item.name,
            path = item.path,
            type = "file",
          })
        )
      end
    end
    return nodes
  end

  local function prepare_node(node)
    local line = NuiLine()

    if node.is_header then
      -- "Relate file (...)" 头部用灰色（与弹窗底部提示一致）
      line:append(node.text, "LineNr")
      return line
    end

    if node.is_separator then
      line:append(" ")
      return line
    end

    local depth = node:get_depth()
    line:append(string.rep("  ", depth - 1))

    if node:has_children() then
      local marks = icons.collapse_marks
      if node:is_expanded() then
        line:append(marks[2] .. " ", "AiderFolder")
      else
        line:append(marks[1] .. " ", "AiderFolder")
      end
    else
      line:append("  ")
    end

    if node.type == "folder" then
      line:append(icons.folder .. " " .. node.text, "AiderFolder")
    elseif node.type == "file" then
      -- 图标引擎适配：优先 nvim-web-devicons，未安装时回退 mini.icons；
      -- 两者皆无则不显示图标
      local icon, hl
      local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
      if ok_devicons then
        icon, hl = devicons.get_icon(node.text, nil, { default = true })
      else
        local ok_mini, mini_icons = pcall(require, "mini.icons")
        if ok_mini then
          icon, hl = mini_icons.get("file", node.text)
        end
      end
      line:append(icon or "", hl)
      line:append(" " .. node.text)
    end

    return line
  end

  local tree = NuiTree({
    bufnr = popup.bufnr,
    ns_id = "herder_agents_file_tree",
    get_node_id = function(node)
      if node.id then
        return node.id
      end
      if node.path then
        return node.path
      end
      return tostring(node)
    end,
    prepare_node = prepare_node,
  })

  local function build_nodes()
    local files_data = session:list_files()
    local added = files_data.added or {}
    local readonly = files_data.readonly or {}
    local all_files = {}
    vim.list_extend(all_files, added)
    vim.list_extend(all_files, readonly)

    local nodes = build_tree_nodes(group_tree_paths(all_files))

    local header = NuiTree.Node({
      id = "header-files",
      text = "Relate file (" .. #all_files .. ")",
      is_header = true,
    }, nodes)
    header:expand()

    return { header }
  end

  local function refresh()
    tree:set_nodes(build_nodes())
    tree:render()
  end

  popup:map("n", "dd", function()
    local node = tree:get_node()
    if not node or node.is_header then
      return
    end
    local paths_to_drop = get_all_file_paths(tree, node)
    if #paths_to_drop == 0 then
      return
    end
    session:drop_files(paths_to_drop)
    refresh()
  end, mapOpts)

  local function clear_files()
    session:clear_files()
    refresh()
  end

  popup:map("n", "D", clear_files, mapOpts)
  popup:map("n", "<C-x>", clear_files, mapOpts)
  prompt_popup:map("n", "<C-x>", clear_files, mapOpts)
  prompt_popup:map("i", "<C-x>", clear_files, mapOpts)

  popup:map("n", "<CR>", function()
    local node = tree:get_node()
    if not node or node.type ~= "file" then
      return
    end
    if layout ~= nil then
      layout:unmount()
    else
      popup:unmount()
    end
    vim.cmd.edit(node.path)
  end, mapOpts)

  popup:map("n", "o", function()
    local node = tree:get_node()
    if not node or not node:has_children() or node.is_header then
      return
    end
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    tree:render()
  end, mapOpts)

  refresh()
  vim.bo[popup.bufnr].filetype = "aider_files"

  return tree
end

function M.show_input(default_value)
  local title = prompt_label
  local opts = { allow_empty = false }
  if default_value ~= nil then
    opts.default_value = default_value
  end
  local session = sessions.current_session()
  local handle_submit = function(value)
    local cwd = vim.fn.getcwd()
    save_history(value, cwd)
    session:send(value)
  end
  local content_popup, prompt_popup, layout = popup_input(title, handle_submit, opts, " AI Chat ")
  setup_file_tree(content_popup, prompt_popup, layout, session)
end

local function session_files()
  local session = sessions.current_session()
  local files_data = session:list_files()
  local all_files = {}
  vim.list_extend(all_files, files_data.added or {})
  vim.list_extend(all_files, files_data.readonly or {})
  return all_files
end

local function build_prompt_with_files(value)
  -- 草稿中已以 @path 形式提及的文件不再重复附加（附件是可编辑文本行，见 herdr_cli_show_input 预填）
  local unmentioned = {}
  for _, file in ipairs(session_files()) do
    if not value:find("@" .. file, 1, true) then
      table.insert(unmentioned, file)
    end
  end
  if #unmentioned == 0 then
    return value
  end
  local files_block = require("herder-agents.context").files_block(unmentioned)
  local prompt = value .. "\n\n" .. files_block
  return (prompt:gsub("\n\n+$", "\n"))
end

local function herdr_cli(...)
  local out = vim.fn.system({ "herdr", ... })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, out)
  return ok and decoded or nil
end

local function herdr_find_pane(label, tab_id)
  local list = herdr_cli("pane", "list")
  local panes = list and list.result and list.result.panes
  if not panes then
    return nil
  end
  for _, pane in ipairs(panes) do
    if pane.label == label and (not tab_id or pane.tab_id == tab_id) then
      return pane
    end
  end
  return nil
end

local function current_herdr_tab_id()
  local current = herdr_cli("pane", "current")
  local current_pane = current and current.result and current.result.pane
  return current_pane and current_pane.tab_id, current_pane
end

local function toggle_cli_in_herdr_pane(cmd, label)
  local tab_id, current_pane = current_herdr_tab_id()
  if not current_pane then
    utils.err("herdr pane current failed; are you inside Herdr?")
    return
  end

  local existing = herdr_find_pane(label, tab_id)
  if existing then
    local layout = herdr_cli("pane", "layout", "--current")
    local zoomed = layout and layout.result and layout.result.layout and layout.result.layout.zoomed
    if zoomed then
      vim.fn.system({ "herdr", "pane", "zoom", "--off", "--current" })
    else
      vim.fn.system({ "herdr", "pane", "zoom", "--on", "--pane", current_pane.pane_id })
    end
    return
  end

  local split = herdr_cli(
    "pane",
    "split",
    "--current",
    "--direction",
    config.options.split.direction,
    "--ratio",
    tostring(config.options.split.ratio),
    "--no-focus",
    "--cwd",
    vim.fn.getcwd()
  )
  local pane_id = split and split.result and split.result.pane and split.result.pane.pane_id
  if not pane_id then
    utils.err("herdr pane split failed")
    return
  end
  local args = { "herdr", "pane", "run", pane_id }
  for _, part in ipairs(vim.split(cmd, " ", { plain = true })) do
    if part ~= "" then
      table.insert(args, part)
    end
  end
  vim.fn.system(args)
  vim.fn.system({ "herdr", "pane", "rename", pane_id, label })
end

local function cli_pane(name)
  local tab_id = current_herdr_tab_id()
  local pane = herdr_find_pane(name, tab_id)
  if not pane then
    local hint = config.options.prefix .. (config.options.keys.toggle or "o")
    utils.err(name .. " pane not found; use " .. hint .. " first")
  end
  return pane
end

local function herdr_cli_toggle(name, cmd)
  if vim.env.HERDR_ENV ~= "1" then
    utils.err(name .. " mode requires Herdr")
    return
  end
  toggle_cli_in_herdr_pane(cmd or name, name)
end

-- bracketed paste 编码（参考 codex.nvim terminal._encode）：
-- 多行文本用 ESC[200~...ESC[201~ 包裹，防止换行被 TUI 逐行当作回车提交；
-- 单行提交同样包裹，规避 codex 的 typing-burst 检测吞掉紧随其后的 enter/tab。
-- 文本结尾处于 @文件 / $技能 补全态时，enter 只会确认补全而不提交，
-- 补一个空格结束 token 让补全关闭（渲染上不可见）；
-- 之前是在末尾补换行把光标顶出补全项，但换行会留在消息里，提交后尾部多出一个空行。
-- 同时归一化换行、清 NUL，并把文本内伪造的粘贴结束符降级为字面量（注入防护）
local function bracketed_paste_encode(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", "")
  text = text:gsub("\27%[201~", "[201~")
  if text:match("[@%$][%w%-%._/:]*$") then
    text = text .. " "
  end
  return "\27[200~" .. text .. "\27[201~"
end

local function herdr_cli_send_prompt(pane_id, tool, text)
  if tool.paste_wrap then
    text = bracketed_paste_encode(text)
  end
  herdr_cli("pane", "send-text", pane_id, text)
end

-- codex 专用 "/queue <任务>"：提交时去掉前缀，最后一个按键为 tab 而非 enter，
-- 触发 codex TUI 的下一个任务（排队）功能；返回 nil 表示输入无效需跳过
local function codex_queue_value(value)
  local task = value:gsub("^/queue%s+", "", 1)
  if task ~= value then
    return task ~= "" and task or nil, "tab"
  end
  if value == "/queue" then
    return nil, "tab"
  end
  return value, "enter"
end

local function herdr_cli_show_input(name, tool, default_value)
  local title = tool.title
  -- 草稿只预填选区上下文（visual 提交）；文件附件不在输入框展示（顶部文件树已有），
  -- 提交时 build_prompt_with_files 统一附加草稿中未提及的文件
  local opts = { allow_empty = false }
  if default_value and default_value ~= "" then
    opts.default_value = default_value
  end
  local session = sessions.current_session()
  local content_popup, prompt_popup, layout = popup_input(prompt_label, function(value)
    local pane = cli_pane(name)
    if not pane then
      return
    end
    local submit_key = "enter"
    if name == "codex" then
      value, submit_key = codex_queue_value(value)
      if not value then
        utils.warn("/queue task is empty, skip")
        return
      end
    end
    save_history(value, vim.fn.getcwd())
    herdr_cli_send_prompt(pane.pane_id, tool, build_prompt_with_files(value))
    herdr_cli("pane", "send-keys", pane.pane_id, submit_key)
  end, opts, title)
  -- 钉住本弹窗的目标工具，供 aider-input 补全源决定技能前缀（qodercli/omp 用 /name，codex 用 $name）
  vim.b[prompt_popup.bufnr].ai_tool = name
  setup_file_tree(content_popup, prompt_popup, layout, session)
end

local function herdr_cli_interrupt(name, key)
  local pane = cli_pane(name)
  if pane then
    herdr_cli("pane", "send-keys", pane.pane_id, key)
  end
end

local function herdr_cli_new_session(name, tool)
  local pane = cli_pane(name)
  if pane then
    herdr_cli_send_prompt(pane.pane_id, tool, tool.new_cmd or "/clear")
    herdr_cli("pane", "send-keys", pane.pane_id, "enter")
  end
end

-- herdr 工具的确定顺序（config.setup 计算：默认序 + 用户新增按字母序）
function M.herdr_tool_names()
  return vim.list_extend({}, config.options.tool_order or {})
end

function M.toggle_tool(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_toggle(name, config.tool_cmd(name))
  end
end

function M.show_input_tool(name, default_value)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_show_input(name, tool, default_value)
  end
end

function M.interrupt_tool(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_interrupt(name, tool.interrupt_key or "ctrl+c")
  end
end

function M.new_tool_session(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_new_session(name, tool)
  end
end

-- 不经输入框，直接向指定工具的 herdr pane 发送 prompt 并回车提交
--（外部调用方使用，如 fzf-lua 诊断修复、sessions.send）
function M.send_tool_prompt(name, text)
  local tool = config.options.tools[name]
  if not tool then
    utils.err(name .. " is not a herdr CLI tool")
    return false
  end
  local pane = cli_pane(name)
  if not pane then
    return false
  end
  herdr_cli_send_prompt(pane.pane_id, tool, text)
  herdr_cli("pane", "send-keys", pane.pane_id, "enter")
  return true
end

-- 供 codex_model 等外部模块复用：执行 herdr CLI 并解析 JSON 结果
function M.herdr_exec(...)
  return herdr_cli(...)
end

-- 供 codex_model 等外部模块复用：按 label 查找当前 tab 的 pane（找不到时给出提示）
function M.find_tool_pane(name)
  return cli_pane(name)
end

function M.show_history(on_select)
  on_select = on_select or M.show_input
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

  local cwd = vim.fn.getcwd()
  local path_history = history[cwd] or {}
  if #path_history == 0 then
    utils.warn("No history found for current directory")
    return
  end

  local Popup = require("nui.popup")
  local NuiText = require("nui.text")
  local line_to_content = {}

  local popup = Popup({
    position = "50%",
    relative = "editor",
    size = {
      width = common.clamp_popup_width(100),
      height = math.min(20, #path_history + 2),
    },
    enter = true,
    border = {
      padding = {
        left = 1,
        right = 1,
        top = 0,
        bottom = 1,
      },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(" Prompt History ", "FloatTitle"),
        top_align = "center",
        bottom = NuiText("<CR>: select | q: close", "NonText"),
        bottom_align = "right",
      },
    },
    buf_options = {
      filetype = "aider-history",
    },
    win_options = {},
  })

  local lines = {}
  for i = #path_history, 1, -1 do
    local entry = path_history[i]
    local timestamp = os.date("%Y-%m-%d %H:%M:%S", entry.timestamp)
    local content = entry.content:gsub("\n", " ")
    if #content > 80 then
      content = content:sub(1, 80) .. "..."
    end
    local display_index = #path_history - i + 1
    table.insert(lines, string.format("%d. [%s] %s", display_index, timestamp, content))
    line_to_content[display_index] = entry.content
  end

  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)

  popup:map("n", "q", function()
    popup:unmount()
  end, mapOpts)
  popup:map("n", "<Esc>", function()
    popup:unmount()
  end, mapOpts)
  popup:map("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(popup.winid)
    local line_num = cursor[1]
    local content = line_to_content[line_num]
    if content then
      popup:unmount()
      on_select(content)
    end
  end, mapOpts)

  popup:mount()
  common.dim(popup.bufnr)
end

return M
