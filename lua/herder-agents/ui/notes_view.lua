-- Notes 审阅/提交弹窗（独立于 Chat 弹窗）
--
-- - 列出全部会话备注，打开时默认全选；<Space>/x 切换勾选，dd 删除
-- - 底部同一 buffer 内一行 "Extra Prompt: - "，可输入附加指令，
--   提交时作为 "- <文本>" 追加在 Notes 块末尾一同发给 agent
-- - 两种提交：<CR> 直接发送（文本 + 回车，agent 立即处理）；
--   <C-a> 仅追加到 agent 输入框（不按回车，可在 TUI 中继续编辑后手动提交）
-- - 显示效果与 Chat 弹窗一致：dim 遮罩 + 空格边框悬浮标题 + NormalFloat 背景
local M = {}

local common = require("herder-agents.ui.common")
local notes = require("herder-agents.notes")
local context = require("herder-agents.context")
local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local mapOpts = { noremap = true }

-- Extra Prompt 行前缀（解析时宽松剥离，容忍用户误删）
local EXTRA_LABEL = "Extra Prompt: - "

-- 弹窗内容高亮的独立命名空间
local ns_view = vim.api.nvim_create_namespace("herder_agents_notes_view")

-- 备注位置标签："rel:行" 或 "rel:起-止"
local function loc_label(note)
  if note.start_line == note.end_line then
    return string.format("%s:%d", note.rel, note.start_line)
  end
  return string.format("%s:%d-%d", note.rel, note.start_line, note.end_line)
end

-- 备注行文本："[x] rel:line  preview"
local function note_line(note)
  local box = note.checked and "[x] " or "[ ] "
  return box .. loc_label(note) .. "  " .. notes.preview_text(note.text)
end

-- 解析 Extra Prompt 行：剥离前缀（容忍前缀被改动）后 trim
local function parse_extra(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last = lines[#lines] or ""
  local extra = last:gsub("^%s*Extra Prompt:%s*", ""):gsub("^%-%s*", "")
  return vim.trim(extra)
end

-- 拼接提交文本：Notes 块（勾选备注）+ Extra Prompt 作为末尾 bullet；
-- 无勾选备注时仅发 Extra Prompt；两者皆空返回 nil
local function build_submit_text(bufnr)
  notes.sync_positions()
  local checked = notes.checked()
  local extra = parse_extra(bufnr)
  local block = context.notes_block(checked)
  if block and extra ~= "" then
    return block .. "\n- " .. extra
  end
  if block then
    return block
  end
  if extra ~= "" then
    return extra
  end
  return nil
end

function M.show()
  local list = notes.list()
  if #list == 0 then
    utils.warn("No notes yet — add one with " .. config.key_hint("note", "<leader>hn"))
    return
  end
  -- 弹框默认全选所有备注
  notes.check_all()
  list = notes.list()

  local Popup = require("nui.popup")
  local NuiText = require("nui.text")

  -- 预渲染各行并计算弹窗尺寸
  local lines = {}
  local line_to_id = {}
  local width = vim.fn.strdisplaywidth(EXTRA_LABEL) + 24
  for i, note in ipairs(list) do
    local text = note_line(note)
    lines[i] = text
    line_to_id[i] = note.id
    width = math.max(width, vim.fn.strdisplaywidth(text))
  end
  local extra_row = #lines + 1
  if #lines > 0 then
    lines[#lines + 1] = "" -- 备注列表与 Extra Prompt 之间的空行分隔
    extra_row = #lines + 1
  end
  lines[extra_row] = EXTRA_LABEL
  -- 底部提示较长，宽度下限保证提示基本完整；上限与 Chat 一致做窗口宽度收敛
  width = math.min(common.clamp_popup_width(90), math.max(76, width + 2))
  -- 最小高度 8 行：备注很少时弹窗也不至于过扁（与 Chat 弹窗体量接近）；上限 20，超出滚动
  local height = math.max(8, math.min(20, extra_row))

  -- 与 Chat 弹窗同款：空格边框 + 悬浮标题/底部提示 + NormalFloat 系背景
  local popup = Popup({
    position = "50%",
    size = { width = width, height = height },
    enter = true,
    border = {
      padding = { left = 1, right = 1, top = 0, bottom = 1 },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(" Notes (" .. #list .. ") ", "FloatTitle"),
        top_align = "center",
        bottom = NuiText(" <CR> send · <C-a> append (no enter) · <Space> toggle · dd delete · q close ", "LineNr"),
        bottom_align = "right",
      },
    },
    buf_options = { filetype = "herder_notes" },
    win_options = {
      winhighlight = "Normal:AiderInputFloatNormal,FloatBorder:AiderInputFloatBorder",
    },
  })

  local bufnr = popup.bufnr

  -- 渲染全部行 + 高亮（勾选框 / 位置 / 预览 / Extra 标签），重建 line_to_id；
  -- 保留用户已输入的 Extra 内容（按上一轮 extra_row 从 buffer 读出，再重算行号）
  local function render()
    local prev = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local kept_extra = (extra_row and prev[extra_row]) or EXTRA_LABEL
    if kept_extra == "" then
      kept_extra = EXTRA_LABEL
    end

    local cur = notes.list()
    lines = {}
    line_to_id = {}
    for i, note in ipairs(cur) do
      lines[i] = note_line(note)
      line_to_id[i] = note.id
    end
    if #lines > 0 then
      lines[#lines + 1] = "" -- 空行分隔（与 show() 初始渲染一致）
    end
    extra_row = #lines + 1
    lines[extra_row] = kept_extra
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(bufnr, ns_view, 0, -1)
    for i, note in ipairs(cur) do
      local box_end = 4 -- "[x] " / "[ ] "
      local loc_end = box_end + #loc_label(note)
      vim.api.nvim_buf_set_extmark(bufnr, ns_view, i - 1, 0, {
        end_col = box_end,
        hl_group = note.checked and "HerderNoteChecked" or "HerderNoteUnchecked",
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns_view, i - 1, box_end, {
        end_col = loc_end,
        hl_group = "HerderNoteLoc",
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns_view, i - 1, loc_end, {
        end_row = i - 1,
        end_col = #lines[i],
        hl_group = "HerderNoteText",
      })
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns_view, extra_row - 1, 0, {
      end_col = math.min(#EXTRA_LABEL, #lines[extra_row]),
      hl_group = "AiderComment",
    })
    -- 标题计数同步（nui 边框文本，保持 FloatTitle 高亮）
    popup.border:set_text("top", NuiText(" Notes (" .. #cur .. ") ", "FloatTitle"), "center")
  end

  local function close()
    popup:unmount()
    -- 提交/取消可能发生在插入模式（Extra Prompt 行键入后直接 C-s/C-Enter/Esc）：
    -- 卸载后焦点回源窗口但插入模式会残留，显式退回 normal，避免误改代码
    if vim.api.nvim_get_mode().mode:match("^[iR]") then
      vim.cmd("stopinsert")
    end
  end

  -- 提交：with_enter=true 直接发送；false 仅追加到 agent 输入框（不按回车）
  local function submit(with_enter)
    local text = build_submit_text(bufnr)
    if not text then
      utils.warn("Nothing to send: no checked notes and empty Extra Prompt")
      return
    end
    local chat = require("herder-agents.ui.chat")
    local name = vim.g.ai_tool or config.options.default_tool
    local ok
    if with_enter then
      ok = chat.send_tool_prompt(name, text)
    else
      ok = chat.append_tool_prompt(name, text)
    end
    if ok then
      close()
    end
  end

  -- 光标所在行的备注 id（Extra 行 / 越界返回 nil）
  local function note_id_at_cursor()
    local row = vim.api.nvim_win_get_cursor(popup.winid)[1]
    return line_to_id[row]
  end

  local function toggle_at_cursor()
    local id = note_id_at_cursor()
    if not id then
      return
    end
    local row = vim.api.nvim_win_get_cursor(popup.winid)[1]
    local col = vim.api.nvim_win_get_cursor(popup.winid)[2]
    notes.toggle(id)
    render()
    pcall(vim.api.nvim_win_set_cursor, popup.winid, { row, col })
  end

  local function delete_at_cursor()
    local id = note_id_at_cursor()
    if not id then
      return
    end
    notes.remove(id)
    render()
  end

  popup:map("n", "<CR>", function()
    submit(true)
  end, mapOpts)
  popup:map("i", "<CR>", function()
    submit(true)
  end, mapOpts)
  popup:map("n", "<C-a>", function()
    submit(false)
  end, mapOpts)
  popup:map("i", "<C-a>", function()
    submit(false)
  end, mapOpts)
  popup:map("n", "<Space>", toggle_at_cursor, mapOpts)
  popup:map("n", "x", toggle_at_cursor, mapOpts)
  popup:map("n", "dd", delete_at_cursor, mapOpts)
  popup:map("n", "q", close, mapOpts)
  popup:map("n", "<Esc>", close, mapOpts)
  popup:map("n", "<C-q>", close, mapOpts)
  popup:map("i", "<C-q>", close, mapOpts)

  popup:mount()
  common.dim(popup.bufnr) -- 与 Chat 一致的全屏遮罩（生命周期挂在弹窗 buffer 上）
  render()

  -- 光标停在第一条备注上（普通模式）：<Space>/x 切换勾选、dd 删除、<CR> 直接提交、
  -- <C-a> 追加不回车；要补 Extra Prompt 时移到末行按 A/i 进入插入
  pcall(vim.api.nvim_win_set_cursor, popup.winid, { 1, 0 })
end

return M
