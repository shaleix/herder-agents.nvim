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

return M
