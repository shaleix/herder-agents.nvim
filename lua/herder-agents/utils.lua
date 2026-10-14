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

local sep_symbol = " > "

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
        return symbol.name .. sep_symbol .. child_symbol
      else
        return symbol.name
      end
    end

    if symbol.children then
      local child = find_symbol(symbol.children, line, col)
      if child then
        return symbol.name .. sep_symbol .. child
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
        symbol = file_name .. sep_symbol .. symbol
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

-- ---------------------------------------------------------------------------
-- 临时文件中转执行（skills api 专用）：`opencode api skill.list` 等大响应 CLI
-- 经管道输出偶发被截断 —— Bun 的 pipe 写入是异步的，CLI 先 process.exit() 导致
-- 缓冲未刷出（退出码仍 0、JSON 不完整；~548KB/65 技能级别必现）。上游 issue
-- anomalyco/opencode#52925，修复 PR #52955（截至 2026-10 未合并）。文件重定向
-- 是同步写、始终完整，故经唯一临时文件中转：
--   sh -c 'exec "$@" > "$0" 2> "$0.err"' <tmp> <argv…>
-- argv 走位置参数（零引号拼接、零注入面）；exec 替换掉 sh，超时 SIGKILL 命中
-- 真实进程。stdout/stderr 都重定向进临时文件还有一个关键作用：CLI 被杀后其
-- 孤儿子进程若仍握着 nvim 的管道，vim.system 会等到管道 EOF 才回调 on_exit
-- （实测 sleep 5 的孤儿让回调迟到 5s）——全走文件则子进程死、管道即 EOF，
-- 回调准时。注意杀掉的进程退出码在部分 nvim 版本报告为 0，但 stdout 必不
-- 完整（空/截断 JSON），失败判定不受影响。
-- 清理保证：两个临时文件在所有退出路径（成功/非零退出/超时/spawn 失败）均
-- 删除、零残留；定时器在所有路径均关闭（不留 libuv 句柄，headless 测试才能
-- 干净退出）。上游修复广泛发布后本层可整体移除（skills.lua 的回退告警同步撤）。
-- 回调契约与 exec_async 一致：on_done({ code, stdout, stderr })。
-- ---------------------------------------------------------------------------

local cli_exec_to_file = nil -- 测试注入：临时文件中转执行器 fun(argv, on_done, timeout_ms)

--- 测试注入：覆盖临时文件中转执行器（传 nil 恢复真实执行）
M.set_exec_to_file = function(fn)
  cli_exec_to_file = fn
end

--- 经临时文件中转的异步执行（argv 数组）：stdout 重定向到唯一临时文件再读回，
--- 规避管道截断（见上方说明）；timeout_ms 给定时 SIGKILL，缺省不设超时
M.exec_async_to_file = function(argv, on_done, timeout_ms)
  if cli_exec_to_file then
    cli_exec_to_file(argv, on_done, timeout_ms)
    return
  end
  -- 无 sh 的奇异平台：退回管道执行（可能受上游截断 bug 影响，聊胜于无；
  -- 正常平台都有 POSIX sh）
  if vim.fn.executable("sh") ~= 1 then
    M.exec_async(argv, on_done)
    return
  end
  local uv = vim.uv or vim.loop
  local tmp = vim.fn.tempname() .. ".json"
  local timer = nil
  local close_timer = function()
    if timer then
      pcall(function()
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end)
      timer = nil
    end
  end
  local cmd = { "sh", "-c", 'exec "$@" > "$0" 2> "$0.err"', tmp }
  vim.list_extend(cmd, argv)
  local ok, sys = pcall(vim.system, cmd, { text = true }, function(r)
    vim.schedule(function()
      close_timer()
      -- 先读后删：stdout 仅在退出码 0 时读回；stderr 恒读（失败诊断用）；
      -- 两个临时文件随后任何路径都删除（零残留）
      local stdout = ""
      if r.code == 0 then
        local ok_read, lines = pcall(vim.fn.readfile, tmp)
        if ok_read and type(lines) == "table" then
          stdout = table.concat(lines, "\n")
        end
      end
      local stderr = r.stderr or ""
      local ok_err, err_lines = pcall(vim.fn.readfile, tmp .. ".err")
      if ok_err and type(err_lines) == "table" and #err_lines > 0 then
        stderr = table.concat(err_lines, "\n")
      end
      pcall(os.remove, tmp)
      pcall(os.remove, tmp .. ".err")
      on_done({ code = r.code, stdout = stdout, stderr = stderr })
    end)
  end)
  if not ok then
    close_timer() -- timer 尚未创建：no-op（保持"每条路径都收定时器"的形状）
    pcall(os.remove, tmp)
    pcall(os.remove, tmp .. ".err")
    on_done({ code = -1, stdout = "", stderr = tostring(sys) })
    return
  end
  if timeout_ms then
    timer = uv.new_timer()
    timer:start(
      timeout_ms,
      0,
      vim.schedule_wrap(function()
        -- SIGKILL：on_exit 仍会触发（部分 nvim 版本把被杀进程报成 code=0，
        -- 但 stdout 必不完整 → 调用方的失败判定不受影响），临时文件统一在
        -- 退出路径清理。注意 SystemObj:kill 是冒号方法，必须显式传 self
        pcall(sys.kill, sys, 9)
        close_timer()
      end)
    )
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

--- 通用选择器：fzf-lua 可用时用 fzf（居中圆角浮窗），未安装时退回 vim.ui.select。
--- 两条路径都恰好回调一次 on_select：选中传候选字符串，取消传 nil（调用方自行判空）
---@param entries string[] 候选列表（字符串）
---@param prompt string 选择器提示文案
---@param on_select fun(choice: string|nil)
function M.pick(entries, prompt, on_select)
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entries, {
      prompt = prompt,
      winopts = {
        width = 0.45,
        height = 0.4,
        row = 0.5,
        col = 0.5,
        border = "rounded",
      },
      actions = {
        ["default"] = function(selected)
          on_select(selected and selected[1] or nil)
        end,
      },
    })
    return
  end
  -- fzf-lua 未安装：退回 vim.ui.select
  vim.ui.select(entries, { prompt = prompt }, on_select)
end

-- ---------------------------------------------------------------------------
-- 终端模式复位（agent 退出后、重启/切换新 agent 前调用）
--
-- 部分 agent TUI（如 codex）退出时不恢复终端私有模式：kitty keyboard
-- protocol（push 未 pop）、SGR 鼠标上报 1000/1002/1003/1006、bracketed paste
-- 2004、隐藏光标等。pane 落回 shell 后 herdr 仍按这些模式把真实按键/鼠标事件
-- 编码成转义序列塞进输入行（"5:1u9;5:1uopencode"；鼠标划过 pane 持续追加
-- "35;4;45M…"），重启命令与残留字节粘连 → command not found → 新 agent 起不来。
--
-- 这些模式只能由 pane 内进程向 tty 输出侧写转义序列关闭（send-text/send-keys
-- 走输入侧，直接发复位序列只会变成输入乱码），因此让 shell 执行一条 printf：
--   - 载荷以 \r 开头：先把已被污染的当前行提交掉（乱码行只会 command not
--     found，无害）；清行与命令在同一次 send-text 写入中原子到达，不会与
--     源源涌入的鼠标事件交错粘连
--   - printf 向输出侧写复位序列（\e 以字面文本传输、由 printf 转成真实 ESC）
-- @param pane_id string 目标 pane
-- @return boolean send-text 是否成功（以退出码判定）
-- ---------------------------------------------------------------------------
M.reset_pane_terminal = function(pane_id)
  local seqs = "\\e[<u\\e[<u" -- kitty keyboard pop ×2（多余 pop 为空操作，兜底未配对的 push）
    .. "\\e[?1000l\\e[?1002l\\e[?1003l\\e[?1006l" -- 关闭 SGR 鼠标上报
    .. "\\e[?2004l" -- 关闭 bracketed paste
    .. "\\e[?25h" -- 恢复光标显示
  return M.exec({ "herdr", "pane", "send-text", pane_id, "\rprintf '" .. seqs .. "'\r" }).code == 0
end

-- 文本结尾是否处于 @文件 / $技能 补全态：注入此类文本后 TUI 会保持补全弹层
-- 打开，紧随其后的回车会被"接受补全"吃掉而非提交 —— 需补一个空格结束
-- token 让补全关闭（agent prompt 与文本通道共用同一判定）
M.ends_in_completion_token = function(text)
  return text:match("[@%$][%w%-%._/:]*$") ~= nil
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
  if M.ends_in_completion_token(text) then
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
