-- herdr pane 控制与 prompt 输入弹窗
--
-- - 工具注册表来自 config.options.tools（setup 可扩展），此处不再硬编码
-- - toggle：当前 tab 无该工具 pane 时分屏启动，已有时切换 pane zoom
-- - input：nui 弹窗草稿（顶部文件树 / 诊断插入 / Ctrl+t 符号路径），
--   提交经 delivery 模块投递（agent 未就绪排队，成败以 herdr 退出码判定，
--   失败保留草稿），不再直接 send-text 即发即忘
local M = {}
local common = require("herder-agents.ui.common")
local sessions = require("herder-agents.sessions")
local notes = require("herder-agents.notes")
local utils = require("herder-agents.utils")
local config = require("herder-agents.config")
local delivery = require("herder-agents.delivery")
local panes = require("herder-agents.panes")

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
    -- on_submit 返回 false = 提交被拒（pane 缺失 / 绑定校验失败 / 投递失败），
    -- 保留草稿供重试（借鉴 codex.nvim ask.lua 的 delivery failure 语义）
    local accepted = on_submit(value)
    if accepted ~= false then
      last_input_content[title] = ""
    end

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

-- 备注位置标签："rel:行" 或 "rel:起-止"
local function note_loc_label(range)
  if range.start_line == range.end_line then
    return string.format("%s:%d", range.rel, range.start_line)
  end
  return string.format("%s:%d-%d", range.rel, range.start_line, range.end_line)
end

-- 内联输入缝隙（note / 行级 prompt 共用 UI）：在目标行下方"撑开"一道缝隙，不覆盖内容：
-- - extmark virt_lines 在锚点行（普通=光标行，可视=选区末行）下方插入虚行，
--   后续内容整体下移；虚拟行无行号、不修改 buffer（不进 undo、不置 modified）
-- - 细线边框输入浮窗用 bufpos 锚定到 buffer 文本坐标（锚点行，第 0 列）：
--   左侧自动与代码内容区对齐（number/sign 列宽自适应），且跟随文本滚动，
--   与同样跟随 buffer 的 virt_lines 缝隙始终严丝合缝
-- - 边框左上为标题、右下为快捷键提示（原生 title/footer），内容背景与 buffer 一致
-- - <C-Enter> 提交（与 Chat 弹窗提交键统一）；<Esc>/q 取消；关闭时缝隙收回，内容弹回原位
--
-- opts 字段：
--   title    边框左上标题文本（自动加 icon 前缀；缺省 "note "）
--   footer   边框右下快捷键提示（缺省 " C-Enter: save · Esc: cancel "）
--   prefill  预填内容（光标到末行行尾进入插入；缺省空白）
--   on_save  fun(text):boolean|nil —— 返回 false 表示提交失败，保留缝隙与内容供重试
local NOTE_INPUT_NS = vim.api.nvim_create_namespace("herder_agents_note_input")
local NOTE_INPUT_ROWS = 2 -- 输入内容区高度
local NOTE_GAP_ROWS = NOTE_INPUT_ROWS + 2 -- 虚行缝隙总高（内容 + 上下边框各 1 行）

local function inline_input_gap(range, opts)
  opts = opts or {}
  local Popup = require("nui.popup")
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = range.bufnr
  local anchor_line = range.end_line
  -- nvim_win_get_width 是窗口总宽【含 sign/number(statuscolumn) 的 textoff】！
  -- 浮窗必须按文本区宽度定尺寸：bufpos 锚在文本第 0 列，若外框宽超过文本区，
  -- 右侧越界会触发 nvim 把浮窗整体左移（顶到窗口第 0 列、盖住行号列）
  local win_info = vim.fn.getwininfo(src_win)[1] or {}
  local textoff = win_info.textoff or 0
  local text_width = math.max(24, vim.api.nvim_win_get_width(src_win) - textoff)
  local win_height = vim.api.nvim_win_get_height(src_win)

  -- 锚点行下方可见空间不足时，滚动窗口腾出缝隙高度
  vim.api.nvim_win_call(src_win, function()
    local row = anchor_line - vim.fn.line("w0") -- 0-based
    if row + NOTE_GAP_ROWS + 1 > win_height - 1 then
      vim.fn.winrestview({ topline = math.max(1, anchor_line - (win_height - NOTE_GAP_ROWS - 3)) })
    end
  end)

  -- 虚拟行撑开缝隙（无行号；buffer 内容零修改）
  local virt_lines = {}
  for _ = 1, NOTE_GAP_ROWS do
    table.insert(virt_lines, { { " " } })
  end
  local virt_id = vim.api.nvim_buf_set_extmark(src_buf, NOTE_INPUT_NS, anchor_line - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    strict = false,
  })

  local cleaned = false
  local function cleanup()
    if cleaned then
      return
    end
    cleaned = true
    if vim.api.nvim_buf_is_valid(src_buf) then
      pcall(vim.api.nvim_buf_del_extmark, src_buf, NOTE_INPUT_NS, virt_id)
    end
  end

  -- 细线边框输入浮窗：bufpos 锚定 buffer 文本坐标（锚点行、第 0 列，0-based），
  -- position 为相对该文本位置的偏移：row=1 → 外框顶线 = 锚点行下一行（缝隙第 1 行）。
  -- 原生边框的 row/col 定位【外框】（含边框）左上角，内容区自动内缩 1 行/列。
  -- 注意：relative="win" 的原点是窗口网格左上角（含 number/sign 列），直接 col=0
  -- 会落到行号区上；bufpos 锚定天然从代码文本区第 0 列开始，且随文本滚动
  local popup = Popup({
    relative = { type = "buf", position = { row = anchor_line - 1, col = 0 } },
    position = { row = 1, col = 0 },
    size = { width = math.max(20, text_width - 2), height = NOTE_INPUT_ROWS },
    enter = true,
    border = { style = "single" }, -- 无 text/padding → nui 原生边框（单窗口）
    buf_options = { filetype = "aider-input" },
    win_options = {
      -- 内容背景与 buffer 一致；边框/标题用 Comment 灰，观感是"嵌在缝隙里"而非浮出
      winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:Comment,FloatTitle:Comment",
    },
  })

  -- 原生 title/footer（渲染在上/下边框线，nvim 0.9+）：左上 icon+标题，右下快捷键提示
  local icon = (config.options.icons and config.options.icons.note) or ""
  popup.win_config.title = {
    { " " .. (icon ~= "" and (icon .. " ") or "") .. (opts.title or "note "), "FloatTitle" },
  }
  popup.win_config.title_pos = "left"
  popup.win_config.footer = { { opts.footer or " C-Enter: save · Esc: cancel ", "FloatTitle" } }
  popup.win_config.footer_pos = "right"

  -- 兜底：浮窗 buffer 被任何途径销毁时收回缝隙，防止虚行残留
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = popup.bufnr,
    once = true,
    callback = cleanup,
  })

  local function close()
    cleanup()
    popup:unmount()
    -- i-mode 映射（C-Enter/Esc）直接关闭时，浮窗卸载后焦点回到源窗口，
    -- 但插入模式会残留 —— 显式退回 normal，避免后续键入误改代码
    if vim.api.nvim_get_mode().mode:match("^[iR]") then
      vim.cmd("stopinsert")
    end
  end

  local function save()
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      utils.warn("Input is empty, skip")
      return
    end
    -- on_save 返回 false = 提交失败（如 agent pane 不在）：保留缝隙与内容供重试
    if opts.on_save and opts.on_save(text) == false then
      return
    end
    close()
  end

  popup:map("n", "<C-Enter>", save, mapOpts)
  popup:map("i", "<C-Enter>", save, mapOpts)
  popup:map("i", "<Esc>", close, mapOpts) -- 内联轻交互：插入模式 Esc 直接取消
  popup:map("n", "<Esc>", close, mapOpts)
  popup:map("n", "q", close, mapOpts)
  popup:map("n", "<C-q>", close, mapOpts)
  popup:map("i", "<C-q>", close, mapOpts)

  popup:mount()
  if opts.prefill and opts.prefill ~= "" then
    -- 预填态（如编辑已有备注）：光标到末行，排入裸 "A"（行尾进入插入，utf8 安全）
    local pre = vim.split(opts.prefill, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, pre)
    pcall(vim.api.nvim_win_set_cursor, popup.winid, { #pre, 0 })
    vim.api.nvim_feedkeys("A", "m", false)
  else
    -- 进入插入模式：排入裸 "i"（noremap），回调返回后由主循环处理。
    -- 不能注入 <Esc>：会命中本窗 n 模式关闭映射；mount 切窗口已自动退出可视模式
    vim.api.nvim_feedkeys("i", "m", false)
  end
end

-- 备注输入：同一位置已有备注时预填进入编辑（保存时原地更新，不重复新建）
local function add_note_inline(range)
  local loc = note_loc_label(range)
  notes.sync_positions()
  local existing = notes.find(range.path, range.start_line, range.end_line)
  inline_input_gap(range, {
    title = existing and "edit note " or "note ",
    prefill = existing and existing.text or nil,
    on_save = function(text)
      if existing and notes.get(existing.id) then
        -- 编辑已有备注：原地更新文本并重渲染 sign/行尾预览（不新建重复条目）
        notes.set_text(existing.id, text)
        utils.info("Note updated @ " .. loc)
      else
        notes.add(range.path, range.start_line, range.end_line, text, range.bufnr)
        utils.info("Note added @ " .. loc)
      end
    end,
  })
end

-- 公开入口：在指定位置添加备注（init.M.add_note 调用，range 见 context.note_range）
function M.add_note(range)
  if not range then
    utils.warn("No location to annotate")
    return
  end
  add_note_inline(range)
end

-- 行级 prompt 直发（init.M.add_prompt 调用）：与 add_note 完全相同的内联缝隙 UI，
-- 但 <C-Enter> 不入备注 store，而是把 "prompt + 目标行定位" 立即发给当前 agent：
--   <prompt>
--
--   Target: @rel (line N) / (lines A-B)
-- @ 引用让 agent 直接读到文件；发送失败（pane 不在 / 已被替换）时缝隙保留可重试。
-- 目标工具在打开时钉住并在保存时校验 pane 绑定，防止键入期间切工具发错会话
function M.add_prompt(range)
  if not range then
    utils.warn("No location to annotate")
    return
  end
  local loc = note_loc_label(range)
  local name = vim.g.ai_tool or config.options.default_tool
  -- 注意：此处只能用 M.* 表访问（bind_tool_pane / deliver_prompt 等局部函数
  -- 定义在文件后方，直接引用会按全局 nil 解析）
  local verify_binding = M.bind_tool_pane(name)
  inline_input_gap(range, {
    title = "prompt ",
    footer = " C-Enter: send · Esc: cancel ",
    on_save = function(text)
      local tool = config.options.tools[name]
      if not tool then
        utils.err(name .. " is not a herdr CLI tool")
        return false
      end
      local pane = panes.lookup(name)
      if not pane then
        utils.warn(name .. " pane not found; use " .. config.key_hint("toggle", "<leader>ho") .. " first")
        return false
      end
      if not verify_binding(pane) then
        return false
      end
      local target
      if range.start_line == range.end_line then
        target = string.format("Target: @%s (line %d)", range.rel, range.start_line)
      else
        target = string.format("Target: @%s (lines %d-%d)", range.rel, range.start_line, range.end_line)
      end
      return M.send_tool_prompt(name, text .. "\n\n" .. target, function(ok)
        if ok then
          utils.info("Prompt delivered → " .. name .. " @ " .. loc)
        end
      end)
    end,
  })
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

-- 草稿会话绑定（借鉴 codex.nvim ask.lua 的 follow-up 绑定）：草稿打开时钉住目标
-- pane，返回校验闭包；提交时对查到的当前 pane 调用，pane 已被关闭/替换
--（switch_replace / codex model 切换会改名复用同一 pane）则拒绝发送，
-- 防止把跟进消息静默发进另一个会话。打开时 pane 还不存在 → 绑定为 nil，
-- 无法校验，放行（pane 缺失的提示由调用方给出）
local function bind_tool_pane(name)
  local bound_pane = panes.lookup(name)
  local bound_pane_id = bound_pane and bound_pane.pane_id or nil
  return function(current_pane)
    return delivery.check_binding(name, bound_pane_id, current_pane)
  end
end

-- bracketed paste 编码已移至 utils.bracketed_paste_encode（delivery 文本通道共用；
-- agent prompt 通道原文直传，不编码 —— 服务端自行处理输入注入）

-- 投递入口：【原文】传给 delivery（借鉴 codex.nvim pending_sends）—— 通道判定后
-- 由 delivery 决定是否编码：agent prompt 通道原文直传，文本通道按 tool.paste_wrap
-- 做 bracketed paste。未就绪时排队；成败以 herdr 退出码判定，
-- 结果经 on_done(ok, queued) 回调告知，不再出现 send-text 失败仍报成功的假成功
local function deliver_prompt(name, pane_id, tool, text, submit_key, on_done)
  return delivery.deliver(pane_id, name, text, {
    submit_key = submit_key,
    on_done = on_done,
    paste_wrap = tool.paste_wrap == true,
  })
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
  -- 草稿会话绑定：打开时钉住目标 pane，提交时校验未被替换（见 bind_tool_pane）
  local verify_binding = bind_tool_pane(name)
  local keep_draft = function(value)
    last_input_content[title] = vim.split(value, "\n", { plain = true })
  end
  local session = sessions.current_session()
  local content_popup, prompt_popup, layout = popup_input(prompt_label, function(value)
    local pane = panes.find(name)
    if not pane then
      return false -- pane 缺失：草稿保留，toggle 后重试（原行为是草稿直接丢失）
    end
    if not verify_binding(pane) then
      return false -- pane 已被替换：草稿保留
    end
    local submit_key = "enter"
    if name == "codex" then
      value, submit_key = codex_queue_value(value)
      if not value then
        utils.warn("/queue task is empty, skip")
        return false
      end
    end
    save_history(value, vim.fn.getcwd())
    local accepted = deliver_prompt(name, pane.pane_id, tool, build_prompt_with_files(value), submit_key, function(ok)
      if not ok then
        -- 投递失败（send-text/send-keys 退出码非 0，或排队后 pane 消失被丢弃）：
        -- 恢复草稿供重试（下次打开输入框预填，历史里也有）
        keep_draft(value)
        utils.err("prompt delivery to " .. name .. " failed; draft kept for retry")
      end
    end)
    return accepted
  end, opts, title)
  -- 钉住本弹窗的目标工具，供 aider-input 补全源决定技能前缀（qodercli/omp 用 /name，codex 用 $name）
  vim.b[prompt_popup.bufnr].ai_tool = name
  setup_file_tree(content_popup, prompt_popup, layout, session)
end

-- herdr 工具的确定顺序（config.setup 计算：默认序 + 用户新增按字母序）
function M.herdr_tool_names()
  return vim.list_extend({}, config.options.tool_order or {})
end

function M.show_input_tool(name, default_value)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_show_input(name, tool, default_value)
  end
end

-- 把 herdr 焦点跳到目标 pane：以调用方 pane（nvim 进程的 HERDR_PANE_ID，注意不能用
-- --current——那解析为 herdr UI 当前聚焦 pane，可能漂在别的 workspace）为基准，
-- 探测目标是哪个方向的直接邻居，再向该方向 focus（跨 workspace/tab 会随焦点切换）。
-- 非直接邻居时返回 false（不做多跳游走，避免焦点乱闪）
local function focus_pane(pane_id)
  local self = vim.env.HERDR_PANE_ID
  if not self or self == "" then
    return false
  end
  for _, dir in ipairs({ "right", "left", "down", "up" }) do
    local res = utils.herdr_json("pane", "neighbor", "--direction", dir, "--pane", self)
    local nb = res and res.result and res.result.neighbor
    if nb and nb.neighbor_pane_id == pane_id then
      utils.herdr_json("pane", "focus", "--direction", dir, "--pane", self)
      return true
    end
  end
  return false
end

-- 通用：按 { cmd } 或 { keys } 配置向工具 pane 发送指令（mode_switch / model_switch 共用）
-- cmd → 发送命令文本并回车；keys → 逐个发送逻辑按键；
-- focus = true → 发送后把 herdr 焦点跳到该 pane（指令打开 pane 内对话框需要上下键选择时用）
local function send_tool_directive(name, spec, what)
  local tool = config.options.tools[name]
  if not tool then
    utils.err(name .. " is not a herdr CLI tool")
    return false
  end
  if type(spec) ~= "table" or (not spec.cmd and not spec.keys) then
    utils.warn(name .. ": no " .. what .. " configured (tools." .. name .. "." .. what .. ")")
    return false
  end
  local pane = panes.find(name)
  if not pane then
    return false
  end
  if spec.cmd then
    -- 命令型指令（如 codex /approvals）同样经 delivery：agent 未就绪时排队，
    -- 实际投递后才报告（投递是异步的，入队成功 ≠ 已发送）
    deliver_prompt(name, pane.pane_id, tool, spec.cmd, "enter", function(ok)
      if ok then
        utils.info(name .. ": " .. what .. " delivered → " .. spec.cmd)
      else
        utils.err(name .. ": " .. what .. " delivery failed → " .. spec.cmd)
      end
    end)
  else
    for _, key in ipairs(spec.keys) do
      -- send-keys 成功时 stdout 为空（非 JSON），只能以退出码判断成败
      if not utils.herdr_ok("pane", "send-keys", pane.pane_id, key) then
        utils.err(what .. " key rejected by herdr: " .. tostring(key))
        return false
      end
    end
    utils.info(name .. ": " .. what .. " keys sent → " .. table.concat(spec.keys, " "))
  end
  if spec.focus and not focus_pane(pane.pane_id) then
    utils.info(name .. ": pane 不是直接邻居，请手动切换 herdr 焦点完成选择")
  end
  return true
end

-- 切换 agent 模式：按工具的 mode_switch 配置经 herdr 发送不同指令
--   opencode v2: { keys = { "shift+tab" } }（agent.cycle 循环 build/plan）
--   codex:       { cmd = "/approvals" }（审批模式选择器）
function M.switch_tool_mode(name)
  local tool = config.options.tools[name]
  return send_tool_directive(name, tool and tool.mode_switch, "mode_switch")
end

-- 切换模型（<leader>hm）：配置了 tools.<name>.models 时走统一流程
-- （平铺单选 → model_apply = "api" 时原地切换（opencode 默认），否则优雅
-- 退出 → model_resume 模板重启，见 model_restart.lua）；
-- 未配置 models 的工具兜底发 model_switch 指令（如 f2 循环最近模型）
function M.switch_tool_model(name)
  local tool = config.options.tools[name]
  if tool and tool.models then
    return require("herder-agents.model_restart").switch(name)
  end
  return send_tool_directive(name, tool and tool.model_switch, "model_switch")
end

-- send_tool_prompt / append_tool_prompt 的共用实现：校验工具与 pane 后经
-- delivery 投递，submit_key 决定是否补提交键（enter = 提交，nil = 仅追加）
local function deliver_to_tool(name, text, submit_key, on_done)
  local tool = config.options.tools[name]
  if not tool then
    utils.err(name .. " is not a herdr CLI tool")
    if on_done then
      on_done(false, false)
    end
    return false
  end
  local pane = panes.find(name)
  if not pane then
    if on_done then
      on_done(false, false)
    end
    return false
  end
  return deliver_prompt(name, pane.pane_id, tool, text, submit_key, on_done)
end

-- 不经输入框，直接向指定工具的 herdr pane 发送 prompt 并回车提交
--（外部调用方使用，如 fzf-lua 诊断修复、sessions.send）。
-- agent 未就绪时排队；on_done(ok, queued) 在实际投递后回调（失败为 false）
function M.send_tool_prompt(name, text, on_done)
  return deliver_to_tool(name, text, "enter", on_done)
end

-- 只把文本追加到指定工具 pane 的 agent 输入框，【不按回车】：
-- 内容停留在 TUI 输入框中，用户可继续编辑后手动提交（notes_view 的 <C-a> 使用）
function M.append_tool_prompt(name, text, on_done)
  return deliver_to_tool(name, text, nil, on_done)
end

-- 供 notes_view / M.add_prompt 复用：草稿会话绑定（见局部 bind_tool_pane 注释），
-- 返回提交时对当前 pane 调用的校验闭包
M.bind_tool_pane = bind_tool_pane

return M
