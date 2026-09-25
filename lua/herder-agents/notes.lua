-- Buffer 备注（会话内存态）：在文件的指定行范围添加备注，
-- 用 extmark 在源缓冲区可视化标记（侧栏 sign + 行尾虚拟文本预览），
-- 在 prompt 弹窗（ui/chat）的 "Notes" 区展示、勾选，提交时把勾选的备注拼进 prompt。
--
-- 备注随 Neovim 生命周期存在（与 sessions 的文件附件一致，不落盘）。
-- extmark 会跟随代码编辑自动移动；发送前调用 sync_positions() 把当前行号写回，
-- 保证备注始终指向正确的代码位置。
local M = {}

local api = vim.api
local utils = require("herder-agents.utils")

-- 备注 extmark 的独立命名空间（与文件树的高亮命名空间互不干扰）
local ns_id = api.nvim_create_namespace("herder_agents_notes")

local next_id = 1
local notes = {} -- id -> note

-- 取备注配置（config.options.notes / icons.note）
local function note_cfg()
  local options = require("herder-agents.config").options
  return options.notes or {}, (options.icons and options.icons.note) or ""
end

-- 首行预览文本（utf8 安全截断，供行尾虚拟文本展示）
local function preview_text(text, max)
  local first = text:match("[^\r\n]+") or ""
  if max and max > 0 and vim.fn.strchars(first) > max then
    first = vim.fn.strcharpart(first, 0, math.max(1, max - 1)) .. "…"
  end
  return first
end

-- 构造备注的 extmark 选项：侧栏 sign + 行尾虚拟文本；
-- end_row 让多行备注的两端都能跟随编辑移动（不设 hl_group，避免整段高亮过于刺眼）
local function extmark_opts(note)
  local cfg, icon = note_cfg()
  local opts = {
    virt_text = { { " " .. preview_text(note.text, cfg.preview_width or 40), "HerderNoteVirt" } },
    virt_text_pos = "eol",
    end_row = note.end_line - 1,
    priority = 20,
  }
  if icon ~= "" then
    opts.sign_text = icon
    opts.sign_hl_group = "HerderNoteSign"
  end
  return opts
end

-- 在指定缓冲区为单条备注创建 extmark（记录 extmark_id / bufnr 以便后续清除或读回）
local function render_note(note, bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  note.bufnr = bufnr
  note.extmark_id = api.nvim_buf_set_extmark(bufnr, ns_id, note.start_line - 1, 0, extmark_opts(note))
end

-- extmark 是否仍存活于该缓冲区（用于判断是否需要重建）
local function extmark_live(note, bufnr)
  if note.bufnr ~= bufnr or not note.extmark_id then
    return false
  end
  local pos = api.nvim_buf_get_extmark_by_id(bufnr, ns_id, note.extmark_id, {})
  return pos ~= nil and pos[1] ~= nil
end

-- 为某缓冲区补齐所有属于它、但当前没有存活 extmark 的备注
--（文件重新打开 / buffer 被 wipe 后重建时调用；已存活的不动，保留编辑跟随）
local function ensure_extmarks(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  for _, note in pairs(notes) do
    if note.path == path and not extmark_live(note, bufnr) then
      render_note(note, bufnr)
    end
  end
end

-- 从 extmark 读回当前行号（跟随编辑后的真实位置）；无法读回时用存储值
local function current_lines(note)
  if note.bufnr and note.extmark_id and api.nvim_buf_is_valid(note.bufnr) then
    local a, b = api.nvim_buf_get_extmark_by_id(note.bufnr, ns_id, note.extmark_id, { details = true })
    -- 兼容两种返回形态：新版单值 [row, col, details]，旧版双值 (pos, details)
    local pos, details
    if type(a) == "table" and type(a[3]) == "table" then
      pos, details = a, a[3]
    else
      pos, details = a, b
    end
    if pos and pos[1] then
      local s = pos[1] + 1
      local e = (details and details.end_row and (details.end_row + 1)) or s
      if e < s then
        e = s
      end
      return s, e
    end
  end
  return note.start_line, note.end_line
end

-- ---------------------------------------------------------------------------
-- 公开 API
-- ---------------------------------------------------------------------------

-- 添加一条备注；bufnr 可选（缺省时按 path 查找已加载的缓冲区）
---@param path string 绝对路径
---@param start_line integer 1-based 起始行
---@param end_line integer 1-based 结束行
---@param text string 备注内容
---@param bufnr integer|nil
---@return table note
function M.add(path, start_line, end_line, text, bufnr)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local note = {
    id = next_id,
    path = path,
    rel = utils.get_relative_path(path),
    start_line = start_line,
    end_line = end_line,
    text = text,
    checked = true, -- 默认勾选，随 prompt 发送
  }
  next_id = next_id + 1
  notes[note.id] = note

  local target = bufnr
  if not target or not api.nvim_buf_is_valid(target) then
    target = vim.fn.bufnr(path)
  end
  if target and target ~= -1 and api.nvim_buf_is_loaded(target) then
    render_note(note, target)
  end
  return note
end

-- 全部备注（按路径、起始行、id 稳定排序，供 UI 与发送使用）
---@return table[]
function M.list()
  local arr = {}
  for _, note in pairs(notes) do
    table.insert(arr, note)
  end
  table.sort(arr, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.start_line ~= b.start_line then
      return a.start_line < b.start_line
    end
    return a.id < b.id
  end)
  return arr
end

-- 已勾选的备注（保持 list() 的顺序）
---@return table[]
function M.checked()
  local arr = {}
  for _, note in ipairs(M.list()) do
    if note.checked then
      table.insert(arr, note)
    end
  end
  return arr
end

function M.get(id)
  return notes[id]
end

-- 切换勾选态，返回新的 checked 值
function M.toggle(id)
  local note = notes[id]
  if not note then
    return nil
  end
  note.checked = not note.checked
  return note.checked
end

-- 删除一条备注（同时清除其 extmark）
function M.remove(id)
  local note = notes[id]
  if not note then
    return
  end
  if note.bufnr and note.extmark_id and api.nvim_buf_is_valid(note.bufnr) then
    pcall(api.nvim_buf_del_extmark, note.bufnr, ns_id, note.extmark_id)
  end
  notes[id] = nil
end

-- 全部勾选（notes_view 弹窗打开时"默认全选"）
function M.check_all()
  for _, note in pairs(notes) do
    note.checked = true
  end
end

-- 清空全部备注
function M.clear()
  local ids = {}
  for id in pairs(notes) do
    table.insert(ids, id)
  end
  for _, id in ipairs(ids) do
    M.remove(id)
  end
end

-- 把所有备注的存储行号同步为 extmark 的当前位置（提交前调用，保证行号准确）
function M.sync_positions()
  for _, note in pairs(notes) do
    note.start_line, note.end_line = current_lines(note)
  end
end

-- 命名空间 id（供测试 / 外部按需清除）
M.ns_id = ns_id

-- 首行预览文本（notes_view 与 extmark 虚拟文本共用）
M.preview_text = preview_text

-- ---------------------------------------------------------------------------
-- 缓冲区自动命令：文件（重新）显示时补齐备注 extmark
-- augroup clear=true 保证幂等（本模块 require 一次即注册一次）
-- ---------------------------------------------------------------------------
local group = api.nvim_create_augroup("HerderAgentsNotes", { clear = true })
api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
  group = group,
  callback = function(ev)
    ensure_extmarks(ev.buf)
  end,
})

return M
