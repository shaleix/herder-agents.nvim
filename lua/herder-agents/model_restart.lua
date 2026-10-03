-- 模型切换（<leader>hm）：所有工具统一「配置候选 → 平铺单选」，选中后按工具配置二选一：
--   A. model_apply = "api"（opencode 默认）：API 原地切换，不退出重启。
--      POST /api/session/{id}/model（与 pane 内 ctrl+x m 模型对话框同源），
--      模型对后续 turn 即时生效，agent working 中也可切
--   B. 重启路径（codex 等）：优雅退出 → 按 model_resume 模板重启
--
-- 候选只来自 tools.<name>.models（两级 provider → [model]，选择时平铺为
-- "provider/model" 单层列表：fzf-lua 可用时用 fzf，否则 vim.ui.select；
-- model 串可带 #variant 后缀，api 路径拆为独立字段、重启路径原样传递）。重启路径：
--   1. 捕获会话 id（session_source）：
--      - codex：herdr 上报的 agent_session；退出后从 pane 尾部
--        "codex resume <id>" 提示兜底（TUI 退出时打印）
--      - opencode：opencode api session.list 按 pane 目录过滤，标题匹配 pane 的
--        terminal_title（"OC | <会话标题>"），无匹配取最新
--   2. 优雅退出：发送 quit_cmd（默认 /quit），轮询前台进程消失
--      （以 pane process-info 为准）；10s 未退重发一次，仍失败 ctrl+c 兜底
--   3. 清行（TUI 清场残留会落进 shell 输入行）后 herdr pane run 按
--      model_resume 模板重启，占位符 {session} {provider} {model}
--   4. 就绪轮询（前台出现非 shell 进程）后报告
--
-- 历史：重启路径曾是 opencode 的默认，但 v2.0.19 的 TUI 顶层不接受 -m
--（仅 run/mini 子命令支持），带 -m 的重启命令会在 pane 内直接报错退出，
-- 表现为"旧的关了、新的没起来"，故 opencode 改走 api 原地切换。
local M = {}

local utils = require("herder-agents.utils")
local chat = require("herder-agents.ui.chat")
local config = require("herder-agents.config")
local delivery = require("herder-agents.delivery")

-- 轮询直到 cond(tick) 为真；超 max_ticks 次后以 false 结束（不阻塞 UI）
local function poll(cond, interval_ms, max_ticks, on_done)
  local tick = 0
  local function step()
    tick = tick + 1
    local ok, res = pcall(cond, tick)
    if ok and res then
      on_done(true)
      return
    end
    if tick >= max_ticks then
      on_done(false)
      return
    end
    vim.defer_fn(step, interval_ms)
  end
  vim.defer_fn(step, interval_ms)
end

-- 两级 { [provider] = { model, ... } } 平铺为 "provider/model" 单层候选；
-- map 遍历顺序不确定，排序保证列表稳定
local function flatten_models(models)
  local entries = {}
  for provider, list in pairs(models or {}) do
    for _, model in ipairs(list) do
      table.insert(entries, provider .. "/" .. model)
    end
  end
  table.sort(entries)
  return entries
end

-- "provider/model[#variant]" → provider, model（model 含 #variant 原样传递）
local function split_entry(entry)
  local sep = entry:find("/", 1, true)
  if not sep then
    return nil, nil
  end
  return entry:sub(1, sep - 1), entry:sub(sep + 1)
end

-- 重启模板占位符替换：{ "codex", "resume", "{session}", "-m", "'{model}'" } 等
local function substitute(tpl, vars)
  local args = {}
  for _, el in ipairs(tpl) do
    table.insert(args, (el:gsub("{(%w+)}", vars)))
  end
  return args
end

local function pick(entries, prompt, on_select)
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
  vim.ui.select(entries, { prompt = prompt }, function(choice)
    on_select(choice)
  end)
end

-- opencode 会话定位：api session.list 按 pane 目录过滤，优先标题精确匹配
--（herdr 的 terminal_title 即 "OC | <会话标题>"），无匹配取最新（列表本就新→旧）
local function opencode_session_id(pane)
  local out = utils.exec({
    "opencode",
    "api",
    "session.list",
    "--param",
    "directory=" .. pane.cwd,
    "--param",
    "limit=20",
  })
  if not out or out.code ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, out.stdout)
  local sessions = ok and decoded and decoded.data or nil
  if type(sessions) ~= "table" or #sessions == 0 then
    return nil
  end
  local title = pane.terminal_title_stripped
  title = title and title:gsub("^OC | ", "") or nil
  for _, s in ipairs(sessions) do
    if title and s.title == title then
      return s.id
    end
  end
  -- 兜底：取 time.updated 最新的会话（不依赖服务端返回顺序）
  local newest = sessions[1]
  for _, s in ipairs(sessions) do
    local nu = newest.time and newest.time.updated or -1
    local su = s.time and s.time.updated or -1
    if su > nu then
      newest = s
    end
  end
  return newest.id
end

-- codex 退出时会在 pane 里打印 "codex resume <id>" 提示；herdr 未上报时兜底抓取
local function codex_resume_hint(pane_id)
  local out = utils.exec({ "herdr", "pane", "read", pane_id, "--lines", "12" })
  if not out or out.code ~= 0 or out.stdout == "" then
    return nil
  end
  return out.stdout:match("codex resume ([%x%-]+)") or nil
end

local function capture_session(source, pane)
  if source == "codex" then
    return pane.agent_session and pane.agent_session.value or nil
  end
  if source == "opencode" then
    local ok, id = pcall(opencode_session_id, pane)
    return ok and id or nil
  end
  return nil
end

-- API 原地切换（opencode，model_apply = "api"）：POST /api/session/{id}/model，
-- 与 pane 内 ctrl+x m 模型对话框同源 —— 模型对当前会话后续 turn 即时生效，
-- 无需退出重启，失败也不影响正在运行的会话。
-- "model#variant" 拆为请求体 Model.Ref 的独立字段（id / providerID / variant）
local function opencode_api_switch(pane, provider, model)
  local ok, session_id = pcall(opencode_session_id, pane)
  if not ok or not session_id then
    utils.err("opencode: 未能定位当前会话 id，已取消切换")
    return false
  end
  local id, variant = model:match("^(.-)#(.+)$")
  local payload = { model = { id = id or model, providerID = provider } }
  if variant then
    payload.model.variant = variant
  end
  local out = utils.exec({
    "opencode",
    "api",
    "post",
    "/api/session/" .. session_id .. "/model",
    "--data",
    vim.json.encode(payload),
  })
  if out.code ~= 0 then
    local detail = (out.stderr ~= "" and out.stderr or out.stdout):gsub("^%s+", ""):gsub("%s+$", "")
    utils.err("opencode 模型切换失败，会话未受影响" .. (detail ~= "" and (": " .. detail) or ""))
    return false
  end
  return true
end

-- pane 前台只剩 shell 视为已退出；查询失败（nil）按未退出继续轮询，
-- 异常场景由后续就绪轮询兜底提示
local function pane_agent_gone(pane_id)
  return delivery.pane_agent_running(pane_id) == false
end

local function quit_agent(pane_id, quit_cmd, on_done)
  local function send_quit()
    chat.herdr_exec("pane", "send-text", pane_id, quit_cmd)
    chat.herdr_exec("pane", "send-keys", pane_id, "enter")
  end
  send_quit()
  -- agent 退出需等待 MCP/hook 清理，网络不佳时可达数十秒
  poll(
    function(tick)
      if pane_agent_gone(pane_id) then
        return true
      end
      -- TUI 初始化期间（启动转圈）quit 命令会被吞掉，10s 后重发一次
      if tick == 20 then
        send_quit()
      end
      return false
    end,
    500,
    60,
    function(ok)
      if ok then
        on_done(true)
        return
      end
      -- quit 未生效（例如任务运行中弹了确认框），ctrl+c 兜底再等一轮
      chat.herdr_exec("pane", "send-keys", pane_id, "ctrl+c")
      poll(
        function()
          return pane_agent_gone(pane_id)
        end,
        500,
        30,
        function(ok2)
          on_done(ok2)
        end
      )
    end
  )
end

local function launch(pane_id, resume_args, on_done)
  -- agent 退出后 TUI 清场的迟到输出会落在 shell 输入行，先清行再 run；
  -- TUI 还可能遗留 kitty keyboard / SGR 鼠标上报等终端私有模式，输入行会被
  -- 编码后的按键/鼠标事件持续污染、启动命令粘连成 "5:1uopencode" ——
  -- 先让 shell 执行 printf 复位载荷关掉这些模式（自带前导 \r 原子清行）
  chat.herdr_exec("pane", "send-keys", pane_id, "ctrl+c")
  utils.reset_pane_terminal(pane_id)
  vim.defer_fn(function()
    -- 复位已生效（不再产生新污染）；printf 执行前排队迟到的事件再补一次
    -- ctrl+c，随后启动命令落在干净提示符上（对齐 replace_tool 的经验）
    chat.herdr_exec("pane", "send-keys", pane_id, "ctrl+c")
    local args = { "herdr", "pane", "run", pane_id }
    vim.list_extend(args, resume_args)
    utils.exec(args)
    -- 就绪判断以前台进程为准（herdr 的 agent 集成检测有秒级延迟）
    poll(
      function()
        return delivery.pane_agent_running(pane_id) == true
      end,
      500,
      60,
      function(ok)
        on_done(ok)
      end
    )
  end, 300)
end

--- 切换工具的 provider/model：平铺单选 → 按工具配置应用
---（model_apply = "api" 原地切换；否则优雅退出 → 按模板重启 resume）
---@param name string 工具名（config.tools 键）
---@return boolean 是否受理（选择与重启为异步流程）
function M.switch(name)
  local tool = config.options.tools[name]
  if not tool or type(tool.models) ~= "table" then
    utils.warn(name .. ": 未配置 models（tools." .. name .. ".models）")
    return false
  end
  if vim.env.HERDR_ENV ~= "1" then
    utils.err("模型切换需要在 Herdr 中使用")
    return false
  end
  local pane = chat.find_tool_pane(name)
  if not pane then
    return false
  end
  local use_api = tool.model_apply == "api"
  -- 重启路径会杀掉运行中的 agent；api 原地切换无此限制（后续 turn 生效）
  if not use_api and (pane.agent_status == "working" or pane.agent_status == "blocked") then
    utils.warn(
      name
        .. " 正在 "
        .. pane.agent_status
        .. "，请先用 "
        .. config.key_hint("interrupt", "<leader>hx")
        .. " 中断后再切换"
    )
    return false
  end
  local entries = flatten_models(tool.models)
  if #entries == 0 then
    utils.warn(name .. ": models 配置为空")
    return false
  end
  local resume_tpl = tool.model_resume
  if not use_api and not resume_tpl then
    utils.warn(name .. ": 未配置 model_resume 重启模板（tools." .. name .. ".model_resume）")
    return false
  end
  local needs_session = resume_tpl and vim.tbl_contains(resume_tpl, "{session}") or false

  pick(entries, name .. " model> ", function(choice)
    if not choice then
      return
    end
    local provider, model = split_entry(choice)
    if not provider then
      utils.err("候选格式错误（应为 provider/model）: " .. choice)
      return
    end
    local target = provider .. "/" .. model

    -- api 原地切换：同步调用即时生效，无退出/重启
    if use_api then
      utils.info(name .. " 切换到 " .. target .. "…")
      if opencode_api_switch(pane, provider, model) then
        utils.info(name .. " 已切换到 " .. target .. "（后续对话即时生效）")
      end
      return
    end

    local session_id = capture_session(tool.session_source, pane)
    -- codex 退出后会打印 resume 提示可二次兜底；其余来源捕获不到就直接取消，
    -- 避免退出后发现无法 resume
    if needs_session and not session_id and tool.session_source ~= "codex" then
      utils.err(name .. ": 未能定位当前会话 id，已取消切换")
      return
    end
    utils.info(name .. " 切换到 " .. target .. " 中，等待退出重启…")

    quit_agent(pane.pane_id, tool.quit_cmd or "/quit", function(ok)
      if not ok then
        utils.err(name .. " 未能退出，已放弃切换；请手动检查 pane")
        return
      end
      if needs_session and not session_id then
        session_id = codex_resume_hint(pane.pane_id)
      end
      if needs_session and not session_id then
        local manual = table.concat(
          substitute(resume_tpl, {
            session = "<session>",
            provider = provider,
            model = model,
          }),
          " "
        )
        utils.err(name .. " 未能捕获会话 id，agent 已退出；请手动重启: " .. manual)
        return
      end
      launch(
        pane.pane_id,
        substitute(resume_tpl, {
          session = session_id or "",
          provider = provider,
          model = model,
        }),
        function(ready)
          if ready then
            utils.info(name .. " 已切换到 " .. target .. (session_id and " 并恢复会话" or ""))
          else
            utils.warn(name .. " 重启命令已发送，但未能确认就绪，请检查 pane")
          end
        end
      )
    end)
  end)
  return true
end

-- 测试导出
M._flatten_models = flatten_models
M._split_entry = split_entry
M._substitute = substitute
M._opencode_session_id = opencode_session_id

return M
