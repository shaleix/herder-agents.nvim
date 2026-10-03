-- prompt 投递：就绪检测 + 排队 + 退出码判定 + 草稿绑定校验
--
-- 借鉴 codex.nvim terminal.lua 的 pending_sends / composer-ready 机制，适配到
-- herdr pane 场景；并优先使用 herdr 的 agent 集成原语（用法参考 herdr-nvim）：
--   - 提交：`herdr agent prompt`（服务端替你按回车、理解 agent 状态机、
--     blocked 时拒绝提交），原文直传，不做 bracketed paste 编码
--   - 等待：`herdr agent wait --until idle/working`（状态机精确等待，
--     分段超时，异步执行避免卡 UI）
-- 仅对 herdr 已注册的 agent pane 生效（按 pane_id 在 agent list 中探测）；
-- 自定义工具 / 未注册 pane / codex /queue（tab 提交）/ append-only 场景回退到
-- pane send-text + bracketed paste + 提交键的旧路径。
--
-- 投递成败以 herdr CLI 退出码判定（修复 send-text 失败仍报 "Prompt sent"
-- 的假成功问题）。
--
-- User 事件（payload 在 event.data）：
--   AIPromptQueued    { tool, pane_id, pending }             prompt 进入排队
--   AIPromptSent      { tool, pane_id, submitted, queued }    投递成功
--   AIDeliveryFailed  { tool, pane_id, queued, reason? }      投递失败 / 队列被丢弃
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

-- state[pane_id] = { items = {...}, polling = boolean, warned = boolean, fail_streak = integer }
local state = {}

local function ensure(pane_id)
  local st = state[pane_id]
  if not st then
    st = { items = {}, polling = false, warned = false, fail_streak = 0 }
    state[pane_id] = st
  end
  return st
end

local function dcfg()
  return config.options.delivery or {}
end

-- pane 前台是否有 agent 进程（非 shell）：
-- 返回 true, 前台进程组 id / false（pane 在 shell）/ nil（查询失败，pane 可能已关闭）。
-- 以 process-info 的前台进程为准（herdr 的 agent 集成检测有秒级延迟，不可靠）；
-- 原 ui/chat 与旧模型切换模块各持一份，收敛到这里单点持有
function M.pane_agent_running(pane_id)
  local info = utils.herdr_json("pane", "process-info", "--pane", pane_id)
  local pi = info and info.result and info.result.process_info
  if not pi then
    return nil
  end
  for _, p in ipairs(pi.foreground_processes or {}) do
    if p.pid ~= pi.shell_pid then
      return true, pi.foreground_process_group_id
    end
  end
  return false
end

-- agent 集成通道探测：pane 是否为 herdr 已注册的 agent。
-- 返回 channel（"agent"|"text"）与 agent_status（仅 agent 通道有值）。
-- agent list 查询失败按文本通道处理（pane 判活仍走 process-info）
local function probe_channel(pane_id)
  if dcfg().agent_channel == false then
    return "text", nil
  end
  local list = utils.herdr_json("agent", "list")
  local agents = list and list.result and list.result.agents
  if type(agents) ~= "table" then
    return "text", nil
  end
  for _, a in ipairs(agents) do
    if a.pane_id == pane_id then
      return "agent", a.agent_status
    end
  end
  return "text", nil
end

local function agent_status_ready(status)
  -- working 也视为就绪：提交交给 herdr 排队/steer，由其状态机处理
  return status == "idle" or status == "working"
end

-- 就绪判定（返回 ready: true|false|nil, channel, status）：
-- 1) agent 通道：状态为 idle/working —— herdr 状态机的精确信号
-- 2) 文本通道（未注册 / 自定义工具 / 通道关闭）：前台进程启发式（原实现）
local function check(pane_id)
  local channel, status = probe_channel(pane_id)
  if channel == "agent" then
    return agent_status_ready(status), channel, status
  end
  local running = M.pane_agent_running(pane_id)
  if running == nil then
    return nil, channel, nil
  end
  return running, channel, nil
end

local function finish_item(item, ok, queued)
  if ok then
    utils.emit("AIPromptSent", {
      tool = item.tool,
      pane_id = item.pane_id,
      submitted = item.submit_key ~= nil,
      queued = queued,
    })
  else
    local payload = { tool = item.tool, pane_id = item.pane_id, queued = queued }
    if item.reason then
      payload.reason = item.reason
    end
    utils.emit("AIDeliveryFailed", payload)
  end
  if item.on_done then
    pcall(item.on_done, ok, queued)
  end
end

-- 投递单条：
-- - agent 通道 + 回车提交 → `herdr agent prompt`（异步；原文直传，不编码）
-- - 其余（文本通道 / tab 提交 / 只插入）→ send-text（按 paste_wrap 编码）+ 可选提交键
-- on_settled 在该条完成后回调（agent 路径为异步完成），供串行 flush 链使用
local function dispatch_item(item, use_agent, queued, on_settled)
  if use_agent and item.submit_key == "enter" then
    utils.exec_async({ "herdr", "agent", "prompt", item.pane_id, item.text }, function(r)
      if r.code ~= 0 then
        item.reason = (r.stderr ~= "" and r.stderr) or ("exit " .. r.code)
      end
      finish_item(item, r.code == 0, queued)
      if on_settled then
        on_settled()
      end
    end)
    return true -- 已受理（异步），结果经 on_done 回调
  end
  local text = item.paste_wrap and utils.bracketed_paste_encode(item.text) or item.text
  local r1 = utils.exec({ "herdr", "pane", "send-text", item.pane_id, text })
  local ok = r1.code == 0
  if not ok then
    item.reason = (r1.stderr ~= "" and r1.stderr) or ("exit " .. r1.code)
  elseif item.submit_key then
    local r2 = utils.exec({ "herdr", "pane", "send-keys", item.pane_id, item.submit_key })
    ok = r2.code == 0
    if not ok then
      item.reason = (r2.stderr ~= "" and r2.stderr) or ("exit " .. r2.code)
    end
  end
  finish_item(item, ok, queued)
  if on_settled then
    on_settled()
  end
  return ok
end

-- 丢弃某 pane 的全部排队项（pane 关闭 / 用户主动丢弃）
local function drop(pane_id, reason)
  local st = state[pane_id]
  if not st then
    return
  end
  st.polling = false
  local items = st.items
  st.items = {}
  if #items == 0 then
    state[pane_id] = nil
    return
  end
  state[pane_id] = nil
  local tool = items[1].tool
  for _, item in ipairs(items) do
    item.reason = reason
    finish_item(item, false, true)
  end
  utils.err("queued prompt for " .. tostring(tool) .. " dropped: " .. reason)
end

local function flush(pane_id, queued)
  local st = ensure(pane_id)
  st.polling = false
  st.warned = false
  st.fail_streak = 0
  local items = st.items
  st.items = {}
  if #items == 0 then
    state[pane_id] = nil
    return
  end
  -- flush 时再探一次通道：settle 窗口里 herdr 可能刚完成注册，赶上 agent 通道
  local use_agent = probe_channel(pane_id) == "agent"
  local index = 0
  local function run_next()
    index = index + 1
    local item = items[index]
    if not item then
      if #st.items == 0 and not st.polling then
        state[pane_id] = nil
      end
      return
    end
    dispatch_item(item, use_agent, queued, run_next)
  end
  run_next()
end

-- 轮询直到就绪再 flush；不阻塞 UI。
-- - agent 通道用 `herdr agent wait --until idle --until working`（异步、分段超时）
--   做服务端精确等待，取代客户端反复轮询
-- - 文本通道保留 defer_fn 轮询（process-info 前台进程启发式 + settle）
-- - pane 判活：process-info 连续失败 pane_gone_retries 次 → 丢弃队列
-- - 排队超过 warn_after_ms 提醒一次（不丢弃，持续等待；codex.nvim 同款语义）
local function kick(pane_id)
  local st = ensure(pane_id)
  if st.polling or #st.items == 0 then
    return
  end
  local d = dcfg()
  local interval = math.max(50, d.poll_interval_ms or 300)
  local settle = math.max(0, d.settle_ms or 300)
  local warn_after = d.warn_after_ms or 5000
  local gone_retries = math.max(1, d.pane_gone_retries or 3)
  local wait_chunk = math.max(interval, d.agent_wait_chunk_ms or 2000)
  st.polling = true
  local waited = 0
  local step -- 前向声明：settle_then_flush 需要捕获本 upvalue
  local function warn_if_due()
    if warn_after > 0 and waited >= warn_after and not st.warned then
      st.warned = true
      local hint = config.key_hint("toggle", "<leader>ho")
      local drop_cmd = config.options.commands and config.options.commands.drop_queue
      utils.warn(
        "prompt for "
          .. tostring(st.items[1] and st.items[1].tool)
          .. " is still queued (agent not ready); start it with "
          .. hint
          .. (drop_cmd and (" or drop with :" .. drop_cmd) or "")
      )
    end
  end
  local function settle_then_flush()
    vim.defer_fn(function()
      if not st.polling or #st.items == 0 then
        return
      end
      if check(pane_id) == true then
        flush(pane_id, true)
      else
        vim.defer_fn(step, interval)
      end
    end, settle)
  end
  step = function()
    if not st.polling or #st.items == 0 then
      st.polling = false
      if #st.items == 0 then
        state[pane_id] = nil
      end
      return
    end
    local ready, channel = check(pane_id)
    if ready == nil then
      st.fail_streak = st.fail_streak + 1
      if st.fail_streak >= gone_retries then
        drop(pane_id, "pane closed or herdr unreachable")
        return
      end
    elseif ready then
      st.fail_streak = 0
      settle_then_flush()
      return
    else
      st.fail_streak = 0
      if channel == "agent" then
        -- 服务端精确等待：agent wait 直到 idle/working；分段超时避免无限阻塞。
        -- 失败（超时 / agent_not_found）回到 step 重新探测，pane 消失由 fail_streak 兜底
        waited = waited + wait_chunk
        warn_if_due()
        utils.exec_async({
          "herdr",
          "agent",
          "wait",
          pane_id,
          "--until",
          "idle",
          "--until",
          "working",
          "--timeout",
          tostring(wait_chunk),
        }, function(r)
          if not st.polling or #st.items == 0 then
            return
          end
          if r.code == 0 then
            settle_then_flush()
          else
            vim.defer_fn(step, interval)
          end
        end)
        return
      end
      waited = waited + interval
      warn_if_due()
    end
    vim.defer_fn(step, interval)
  end
  vim.defer_fn(step, interval)
end

--- 把文本投递到 pane：就绪则立即发送，否则排队等就绪。
--- opts: { submit_key?: string（"enter" 走 agent prompt，其余走文本通道）,
---         paste_wrap?: boolean（文本通道是否 bracketed paste 编码）,
---         on_done?: fun(ok: boolean, queued: boolean) }
--- 返回 true 表示已发送 / 已受理（agent 通道异步）/ 已排队；false 表示立即投递失败
function M.deliver(pane_id, tool, text, opts)
  opts = opts or {}
  local item = {
    pane_id = pane_id,
    tool = tool,
    text = text,
    submit_key = opts.submit_key,
    on_done = opts.on_done,
    paste_wrap = opts.paste_wrap == true,
  }
  if dcfg().enabled == false then
    -- 排队关闭：直接文本通道发送（旧版即发即忘行为，保留退出码判定）
    return dispatch_item(item, false, false)
  end
  local ready, channel = check(pane_id)
  if ready == true then
    return dispatch_item(item, channel == "agent", false)
  end
  -- 未就绪 / 查询瞬时失败：排队交给轮询判定
  local st = ensure(pane_id)
  table.insert(st.items, item)
  utils.emit("AIPromptQueued", { tool = tool, pane_id = pane_id, pending = #st.items })
  kick(pane_id)
  return true
end

--- 草稿绑定校验（借鉴 codex.nvim ask.lua 的 follow-up 绑定）：
--- 草稿打开时记录目标 pane（bound_pane_id，nil = 当时无 pane，无法校验），
--- 提交时校验 pane 未被关闭/替换 —— replace_tool / codex model 切换会改名
--- 复用同一 pane，仅按 label 查找会静默发到另一个会话
function M.check_binding(name, bound_pane_id, pane)
  if not bound_pane_id or not pane then
    return true
  end
  if pane.pane_id ~= bound_pane_id then
    utils.err(
      name .. " pane was replaced while the draft was open; draft kept — reopen and resend to the new session"
    )
    return false
  end
  return true
end

--- 丢弃全部排队中的 prompt（:AIDropQueue）；返回丢弃条数
function M.drop_all()
  local count = 0
  for pane_id in pairs(state) do
    local st = state[pane_id]
    count = count + #st.items
    drop(pane_id, "dropped by user")
  end
  if count == 0 then
    utils.info("no queued prompts")
  end
  return count
end

function M.pending_count()
  local count = 0
  for _, st in pairs(state) do
    count = count + #st.items
  end
  return count
end

-- 测试辅助：清空内部状态（配合 utils.set_exec 注入假执行器使用）
function M._reset()
  state = {}
end

return M
