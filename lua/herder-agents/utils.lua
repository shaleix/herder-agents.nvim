local M = {}

local function get_notify_msg(msg)
  if type(msg) == "table" then
    return table.concat(msg, "\n")
  end
  return msg
end

M.info = function(msg, title)
  vim.notify(get_notify_msg(msg), vim.log.levels.INFO, { title = title or "Herder Agents" })
end

M.err = function(msg, title)
  vim.notify(get_notify_msg(msg), vim.log.levels.ERROR, { title = title or "Herder Agents" })
end

M.warn = function(msg, title)
  vim.notify(get_notify_msg(msg), vim.log.levels.WARN, { title = title or "Herder Agents" })
end

function M.get_relative_path(file_path)
  local cwd = vim.fn.getcwd()
  local relative_path = file_path
  if string.sub(file_path, 1, #cwd) == cwd then
    relative_path = string.sub(file_path, #cwd + 2) -- +2 to remove cwd and the trailing slash
  end
  return relative_path
end

local function find_symbol(symbols, line, col)
  for _, symbol in ipairs(symbols) do
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      goto continue
    end

    if
      range.start.line <= line
      and range["end"].line >= line
      and range.start.character <= col
      and (range["end"].line > line or range["end"].character >= col)
    then
      local child_symbol = nil
      if symbol.children then
        child_symbol = find_symbol(symbol.children, line, col)
      end
      if child_symbol then
        return symbol.name .. M.sep_symbol .. child_symbol
      else
        return symbol.name
      end
    end

    if symbol.children then
      local child = find_symbol(symbol.children, line, col)
      if child then
        return symbol.name .. M.sep_symbol .. child
      end
    end

    ::continue::
  end
  return nil
end

-- 取光标处的 LSP 符号路径（文件名 > 符号 > 子符号），供 prompt 的 Ctrl+t 插入
-- "Target position: ..." 行；无 documentSymbol 能力的 LSP 时回调 on_not_supported
function M.get_current_path(callback, on_not_supported)
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local line, col = pos[1] - 1, pos[2]

  local path = vim.api.nvim_buf_get_name(0)
  local file_name = (path == "" and "Empty") or path:match("([^/\\]+)[/\\]*$")

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }

  -- 提前检测：没有支持 documentSymbol 的 LSP 时直接走 fallback，避免 vim.lsp 弹错误通知
  local ok, clients = pcall(vim.lsp.get_clients, { bufnr = bufnr, method = "textDocument/documentSymbol" })
  if not ok or not clients or #clients == 0 then
    if on_not_supported then
      on_not_supported()
    end
    return
  end

  vim.lsp.buf_request_all(bufnr, "textDocument/documentSymbol", params, function(responses)
    for _, res in pairs(responses or {}) do
      if not res.err and res.result and #res.result > 0 then
        local symbol = find_symbol(res.result, line, col)
        if not symbol then
          return
        end
        symbol = file_name .. M.sep_symbol .. symbol
        if callback then
          callback(symbol)
        end
        return
      end
    end
    if on_not_supported then
      on_not_supported()
    end
  end)
end

M.sep_symbol = " > "

-- ---------------------------------------------------------------------------
-- CLI 执行基建（借鉴 herdr-nvim exec.lua 的注入模式）：
-- 统一走 vim.system（返回 {code, stdout, stderr}，无 vim.v.shell_error 全局态），
-- 并提供测试注入点 —— set_exec/set_exec_async 换成假执行器后，delivery/status
-- 的全部逻辑可以在无真实 herdr 的环境下单测
-- ---------------------------------------------------------------------------

local cli_exec = nil -- 测试注入：同步执行器 fun(argv): {code, stdout, stderr}
local cli_exec_async = nil -- 测试注入：异步执行器 fun(argv, on_done)

--- 测试注入：覆盖同步执行器（传 nil 恢复真实执行）
M.set_exec = function(fn)
  cli_exec = fn
end

--- 测试注入：覆盖异步执行器（传 nil 恢复真实执行）
M.set_exec_async = function(fn)
  cli_exec_async = fn
end

local function to_result(r)
  return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
end

--- 同步执行（argv 数组，无 shell），返回 { code, stdout, stderr }
M.exec = function(argv)
  if cli_exec then
    return cli_exec(argv)
  end
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait()
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return to_result(res)
end

--- 异步执行（argv 数组）：完成经 vim.schedule 回调 on_done(result)，
--- 供可能阻塞的调用（agent prompt / agent wait）使用，避免卡 UI
M.exec_async = function(argv, on_done)
  if cli_exec_async then
    cli_exec_async(argv, on_done)
    return
  end
  local ok, err = pcall(vim.system, argv, { text = true }, function(r)
    vim.schedule(function()
      on_done(to_result(r))
    end)
  end)
  if not ok then
    on_done({ code = -1, stdout = "", stderr = tostring(err) })
  end
end

-- herdr CLI 封装（输出 JSON 的子命令，如 pane list / agent list / process-info）：
-- 失败或输出非 JSON 时返回 nil
M.herdr_json = function(...)
  local r = M.exec({ "herdr", ... })
  if r.code ~= 0 or r.stdout == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  if not ok then
    return nil
  end
  return decoded
end

-- herdr CLI 封装（无 JSON 输出的子命令，如 pane send-text / send-keys）：
-- 成功时 stdout 为空（非 JSON），只能以退出码判断成败
M.herdr_ok = function(...)
  return M.exec({ "herdr", ... }).code == 0
end

-- bracketed paste 编码（原 ui/chat 实现，移至 utils 供 delivery 文本通道共用；
-- agent prompt 通道不做此编码 —— 服务端自行处理输入注入）：
-- - 多行文本用 ESC[200~...ESC[201~ 包裹，防止换行被 TUI 逐行当作回车提交
-- - 单行提交同样包裹，规避 codex 的 typing-burst 检测吞掉紧随其后的 enter/tab
-- - 文本结尾处于 @文件 / $技能 补全态时，补一个空格结束 token 让补全关闭
-- - 归一化换行、清 NUL，并把文本内伪造的粘贴结束符降级为字面量（注入防护）
M.bracketed_paste_encode = function(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", "")
  text = text:gsub("\27%[201~", "[201~")
  if text:match("[@%$][%w%-%._/:]*$") then
    text = text .. " "
  end
  return "\27[200~" .. text .. "\27[201~"
end

-- 发 User autocmd 生命周期事件（payload 在 event.data；借鉴 codex.nvim 的事件约定）
M.emit = function(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data or {},
  })
end

return M
