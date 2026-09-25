-- 上下文格式化：选区 / 文件附件 / 诊断
-- 格式参考 codex.nvim（nwiizo）context.lua：
-- - 选区：`@绝对路径 (lines a-b)` + 自适应长度 fence 代码块
-- - 文件：纯文本 mention 行（`- @路径`）
-- - 诊断：`Diagnostics from @路径:` + `行:列 Severity: message` 行
-- 附件一律是可编辑的纯文本行，用户可在草稿中直接增删
local M = {}

-- fence 长度自适应：选区内容含 ``` 时逐级加长，防止围栏冲突
local function fence_for(text)
  local longest = 3
  for run in text:gmatch("`+") do
    if #run + 1 > longest then
      longest = #run + 1
    end
  end
  return string.rep("`", longest)
end

-- 当前缓冲区的最近选区（'< '> mark）；无选区或无名缓冲区返回 nil
function M.selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, end_line = start_pos[2], end_pos[2]
  if start_line < 1 or end_line < 1 then
    return nil
  end
  local regtype = vim.fn.visualmode()
  if regtype == "" then
    -- 无可视模式历史（如 headless）：按行选取兜底
    regtype = "V"
  end
  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = regtype })
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local text = table.concat(lines, "\n")
  local ft = vim.bo[bufnr].filetype or ""
  local fence = fence_for(text)
  return string.format(
    "Use this Neovim selection from @%s (lines %d-%d):\n%s%s\n%s\n%s",
    path,
    start_line,
    end_line,
    fence,
    ft,
    text,
    fence
  )
end

-- 会话文件列表 → "Relate file:" 附件块；空列表返回 nil
function M.files_block(files)
  if not files or #files == 0 then
    return nil
  end
  local lines = { "Relate file:" }
  for _, file in ipairs(files) do
    table.insert(lines, "- @" .. file)
  end
  return table.concat(lines, "\n")
end

-- 勾选的备注 → "Notes:" 块；空列表返回 nil
-- 每条格式：`- @相对路径 (line N): 内容` 或 `(lines A-B): 内容`（多行内容压成单行）
function M.notes_block(note_list)
  if not note_list or #note_list == 0 then
    return nil
  end
  local lines = { "Notes:" }
  for _, note in ipairs(note_list) do
    local loc
    if note.start_line == note.end_line then
      loc = string.format("(line %d)", note.start_line)
    else
      loc = string.format("(lines %d-%d)", note.start_line, note.end_line)
    end
    local text = (note.text or ""):gsub("\r?\n", " "):gsub("^%s*(.-)%s*$", "%1")
    table.insert(lines, string.format("- @%s %s: %s", note.rel, loc, text))
  end
  return table.concat(lines, "\n")
end

-- 当前备注位置：可视模式取选区起止行，普通模式取光标行；
-- 无名缓冲区返回 nil。返回 { path, rel, bufnr, start_line, end_line }
-- 选区行号沿用 selection() 的 '< '> mark 方式，与本插件既有行为一致
function M.note_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local start_line, end_line
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("[vV\22]") then
    local s = vim.fn.getpos("'<")[2]
    local e = vim.fn.getpos("'>")[2]
    if s >= 1 and e >= 1 then
      start_line, end_line = math.min(s, e), math.max(s, e)
    end
  end
  if not start_line then
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    start_line, end_line = cur, cur
  end
  return {
    path = path,
    rel = require("herder-agents.utils").get_relative_path(path),
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
  }
end

-- 缓冲区诊断块；无诊断或无名缓冲区返回 nil
function M.diagnostics(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local diags = vim.diagnostic.get(bufnr)
  if #diags == 0 then
    return nil
  end
  table.sort(diags, function(a, b)
    if a.lnum == b.lnum then
      return a.col < b.col
    end
    return a.lnum < b.lnum
  end)
  local lines = { "Diagnostics from @" .. path .. ":" }
  for _, d in ipairs(diags) do
    local message = d.message:gsub("\n", " ")
    table.insert(
      lines,
      string.format("%d:%d %s: %s", d.lnum + 1, d.col + 1, vim.diagnostic.severity[d.severity], message)
    )
  end
  return table.concat(lines, "\n")
end

return M
