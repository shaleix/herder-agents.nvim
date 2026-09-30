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

-- 上下文大小上限（借鉴 codex.nvim context.check_limits：超限拒绝而非静默截断，
-- 避免一次误全选把几 MB 灌进 bracketed paste）；返回错误消息或 nil
function M._check_limits(lines, text)
  local limits = require("herder-agents.config").options.context or {}
  local max_lines = limits.max_lines or 500
  local max_bytes = limits.max_bytes or 65536
  if #lines > max_lines then
    return string.format("selection has %d lines; limit is %d", #lines, max_lines)
  end
  if #text > max_bytes then
    return string.format("selection has %d bytes; limit is %d", #text, max_bytes)
  end
  return nil
end

-- 当前缓冲区的活动可视选区（x 模式映射回调内调用）；非可视模式 / 无名缓冲区返回 nil
-- 注意：回调执行期间 '< '> mark 与 visualmode() 是【上一次】选区的陈旧值
--（退出可视模式才更新，首次选区时为 0/""），当前选区必须用 'v'（锚点）+ 光标位置，
-- 运动类型直接取 mode()（"v"/"V"/"^V" 即 getregion 的 type 值）
-- 返回 prompt, err：无选区/无名缓冲区时两者皆 nil；超过 context 上限时
-- 返回 nil + 错误消息（拒绝而非截断，调用方负责提示）
function M.selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("[vV\22]") then
    return nil -- 'v' 锚点只在活动可视选区内可靠
  end
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getcurpos()
  -- 从下往上选时锚点行在光标行之下：归一化行序，保证 (lines a-b) 恒为 a<=b
  --（codex.nvim context._selection_text 同款 math.min/math.max 处理）
  local start_line, end_line = start_pos[2], end_pos[2]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  if start_line < 1 or end_line < 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local text = table.concat(lines, "\n")
  local limit_err = M._check_limits(lines, text)
  if limit_err then
    return nil, limit_err
  end
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
  ),
    nil
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

-- 勾选的备注 → review 注释块；空列表返回 nil
-- 标题用指令句（告诉 agent 这是需要修改的 review 注释），可用 notes.submit_header 自定义；
-- 每条格式：`- @相对路径 (line N): 内容` 或 `(lines A-B): 内容`（多行内容压成单行）
function M.notes_block(note_list)
  if not note_list or #note_list == 0 then
    return nil
  end
  local notes_cfg = require("herder-agents.config").options.notes or {}
  local lines = { notes_cfg.submit_header or "Please address these code review comments:" }
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
-- 可视选区用 'v'（锚点）+ 光标行获取——x 模式映射回调期间 '< '> 是上一次的陈旧 mark
function M.note_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local start_line, end_line
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("[vV\22]") then
    local anchor = vim.fn.getpos("v")[2]
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    if anchor >= 1 and cur >= 1 then
      start_line, end_line = math.min(anchor, cur), math.max(anchor, cur)
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
