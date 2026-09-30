-- prompt 投递：就绪检测 + 排队 + 退出码判定 + 草稿绑定校验
--
-- 借鉴 codex.nvim terminal.lua 的 pending_sends / composer-ready 机制，适配到
-- herdr pane 场景。codex.nvim 拥有子进程 stdout，可以扫 ANSI 光标序列判断
-- Codex TUI 的输入框就绪；本插件拿不到 pane 内 stdout，就绪信号退而求其次用
-- pane 的前台进程（herdr pane process-info）：agent 进程在前台即视为就绪，
-- 再加一段 settle 稳定期避开 TUI 初始化窗口。pane 内的交互式启动对话框
-- （如 codex 的 trust 提示）无法检测，需要用户手动处理；warn_after_ms 会提醒。
--
-- 投递成败以 herdr CLI 退出码判定（send-text/send-keys 成功时 stdout 非 JSON），
-- 修复原先 send-text 失败仍报 "Prompt sent" 的假成功问题。
--
-- User 事件（payload 在 event.data）：
--   AIPromptQueued    { tool, pane_id, pending }    prompt 进入排队
--   AIPromptSent      { tool, pane_id, submitted, queued } 投递成功
--   AIDeliveryFailed  { tool, pane_id, queued }     投递失败 / 队列被丢弃
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
-- 原 ui/chat 与 codex_model 各持一份，收敛到这里单点持有
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

-- 就绪判定：前台进程存在；可选要求 herdr 的 agent 集成已识别出状态
--（require_agent_status：更保守，能额外过滤 herdr 尚未识别 agent 的启动窗口）
local function pane_ready(pane_id)
  local running = M.pane_agent_running(pane_id)
  if running ~= true then
    return running -- false = 未就绪；nil = 查询失败
  end
  if dcfg().require_agent_status then
    local list = utils.herdr_json("pane", "list")
    local panes = list and list.result and list.result.panes or {}
    for _, pane in ipairs(panes) do
      if pane.pane_id == pane_id then
        return pane.agent_status ~= nil and pane.agent_status ~= ""
      end
    end
    return false
  end
  return true
end

-- 一次投递：send-text + 可选提交键；以退出码判定成败
local function deliver_item(item)
  local ok = utils.herdr_ok("pane", "send-text", item.pane_id, item.text)
  if ok and item.submit_key then
    ok = utils.herdr_ok("pane", "send-keys", item.pane_id, item.submit_key)
  end
  return ok
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
    utils.emit("AIDeliveryFailed", { tool = item.tool, pane_id = item.pane_id, queued = queued })
  end
  if item.on_done then
    pcall(item.on_done, ok, queued)
  end
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
  for _, item in ipairs(items) do
    finish_item(item, deliver_item(item), queued)
  end
  -- on_done 回调里可能同步再次投递（已自行 kick），只在确实空闲时回收 state
  if #st.items == 0 and not st.polling then
    state[pane_id] = nil
  end
end

-- 轮询直到就绪再 flush；不阻塞 UI（defer_fn 链）。
-- - 查询连续失败 pane_gone_retries 次 → 判定 pane 已关闭，丢弃队列
-- - 就绪后先等 settle_ms 稳定期（避开 TUI 初始化），期间掉回未就绪则继续等
-- - 排队超过 warn_after_ms 提醒一次（不丢弃，持续等待；codex.nvim 同款语义）
-- ready_hint：入队时已探得就绪，跳过首个轮询间隔直接进 settle 复检
local function kick(pane_id, ready_hint)
  local st = ensure(pane_id)
  if st.polling or #st.items == 0 then
    return
  end
  local d = dcfg()
  local interval = math.max(50, d.poll_interval_ms or 300)
  local settle = math.max(0, d.settle_ms or 300)
  local warn_after = d.warn_after_ms or 5000
  local gone_retries = math.max(1, d.pane_gone_retries or 3)
  st.polling = true
  local waited = 0
  local step, settle_check
  -- 就绪复检：settle 稳定期后 agent 仍在前台才 flush；掉回未就绪则继续轮询
  settle_check = function(queued)
    vim.defer_fn(function()
      if not st.polling or #st.items == 0 then
        return
      end
      if pane_ready(pane_id) == true then
        flush(pane_id, queued)
      else
        vim.defer_fn(step, interval)
      end
    end, settle)
  end
  step = function()
    -- 已被 drop/flush 接管（polling 置 false）或队列已空：停链并回收空闲 state
    if not st.polling or #st.items == 0 then
      st.polling = false
      if #st.items == 0 then
        state[pane_id] = nil
      end
      return
    end
    local ready = pane_ready(pane_id)
    if ready == nil then
      st.fail_streak = st.fail_streak + 1
      if st.fail_streak >= gone_retries then
        drop(pane_id, "pane closed or herdr unreachable")
        return
      end
    else
      st.fail_streak = 0
      if ready then
        settle_check(true)
        return
      end
      waited = waited + interval
      if warn_after > 0 and waited >= warn_after and not st.warned then
        st.warned = true
        local hint = config.key_hint("toggle", "<leader>ho")
        local drop_cmd = config.options.commands and config.options.commands.drop_queue
        utils.warn(
          "prompt for "
            .. tostring(st.items[1].tool)
            .. " is still queued (agent not ready); start it with "
            .. hint
            .. (drop_cmd and (" or drop with :" .. drop_cmd) or "")
        )
      end
    end
    vim.defer_fn(step, interval)
  end
  if ready_hint then
    settle_check(false)
  else
    vim.defer_fn(step, interval)
  end
end

--- 把文本投递到 pane：入队后等就绪（settle 复检）自动发送
---@param pane_id string
---@param tool string 工具名（事件 payload 用）
---@param text string 已完成编码（paste_wrap 等）的最终文本
---@param opts table|nil { submit_key?: string（如 "enter"，nil=只插入不提交）, on_done?: fun(ok: boolean, queued: boolean) }
---@return boolean true 表示已入队等待投递；false 表示立即投递失败
---（仅 delivery.enabled = false 的同步直发路径，成败以 herdr 退出码判定）
function M.deliver(pane_id, tool, text, opts)
  opts = opts or {}
  local item = {
    pane_id = pane_id,
    tool = tool,
    text = text,
    submit_key = opts.submit_key,
    on_done = opts.on_done,
  }
  if dcfg().enabled == false then
    -- 排队关闭：保持旧版即发即忘行为，但仍以退出码判定成败
    local ok = deliver_item(item)
    finish_item(item, ok, false)
    return ok
  end
  -- 一律入队走同一套 settle 复检：入队时就绪也经稳定期（避开 TUI 初始化窗口），
  -- 只是跳过首个轮询间隔尽快发送；ready 为 false/nil（shell 中 / 查询瞬时失败）
  -- 则照常轮询。结果统一经 on_done 异步告知
  local st = ensure(pane_id)
  table.insert(st.items, item)
  utils.emit("AIPromptQueued", { tool = tool, pane_id = pane_id, pending = #st.items })
  kick(pane_id, pane_ready(pane_id) == true)
  return true
end

--- 草稿绑定校验（借鉴 codex.nvim ask.lua 的 follow-up 绑定）：
--- 草稿打开时记录目标 pane（bound_pane_id，nil = 当时无 pane，无法校验），
--- 提交时校验 pane 未被关闭/替换 —— replace_tool / codex model 切换会改名
--- 复用同一 pane，仅按 label 查找会静默发到另一个会话
---@param name string 工具名（提示消息用）
---@param bound_pane_id string|nil
---@param pane table|nil 提交时查到的当前 pane（调用方已确保 label == name）
---@return boolean
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
---@return integer
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

-- 测试辅助：清空内部状态（不打真实 herdr 调用）
function M._reset()
  state = {}
end

return M
