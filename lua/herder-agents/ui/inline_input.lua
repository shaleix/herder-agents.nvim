-- 内联输入缝隙引擎（note / 行级 prompt 共用 UI）：自 ui/chat 抽出的独立模块
--
-- 在目标行下方"撑开"一道缝隙，不覆盖内容：
-- - extmark virt_lines 在锚点行（普通=光标行，可视=选区末行）下方插入虚行，
--   后续内容整体下移；虚拟行无行号、不修改 buffer（不进 undo、不置 modified）
-- - 细线边框输入浮窗用 bufpos 锚定到 buffer 文本坐标（锚点行，第 0 列）：
--   左侧自动与代码内容区对齐（number/sign 列宽自适应），且跟随文本滚动，
--   与同样跟随 buffer 的 virt_lines 缝隙始终严丝合缝
-- - 边框左上为标题、右下为快捷键提示（原生 title/footer），内容背景与 buffer 一致
-- - <C-Enter> 提交（与 Chat 弹窗提交键统一）；<Esc>/q 取消；关闭时缝隙收回，内容弹回原位
--
-- M.open(range, opts)：
--   range        context.note_range 形状：bufnr / start_line / end_line
--                （缝隙撑在 end_line 下方，普通=光标行、可视=选区末行）
--   opts 字段：
--     title    边框左上标题文本（自动加 icon 前缀；缺省 "note "）
--     footer   边框右下快捷键提示（缺省 " C-Enter: save · Esc: cancel "）
--     prefill  预填内容（光标到末行行尾进入插入；缺省空白）
--     pane_id  绑定的 agent pane（写入 vim.b.pane_id，供 herdr:<pane_id> 提及
--              补全判定"当前 agent"；缺省不绑定 —— note 输入无 agent 绑定）
--     on_save  fun(text):boolean|nil —— 返回 false 表示提交失败，保留缝隙与内容供重试
local M = {}
local mapOpts = { noremap = true }
local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local NOTE_INPUT_NS = vim.api.nvim_create_namespace("herder_agents_note_input")
local NOTE_INPUT_ROWS = 2 -- 输入内容区高度
local NOTE_GAP_ROWS = NOTE_INPUT_ROWS + 2 -- 虚行缝隙总高（内容 + 上下边框各 1 行）

function M.open(range, opts)
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
  -- 绑定 agent pane（与 chat 弹窗的 vim.b.ai_tool 同款约定）：herdr:<pane_id>
  -- 提及补全据 vim.b.pane_id 标记"当前 agent"（缺省不设置 —— 无 current 标记）
  if opts.pane_id then
    vim.b[popup.bufnr].pane_id = opts.pane_id
  end

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

return M
