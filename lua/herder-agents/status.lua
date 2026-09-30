-- agent 状态轮询 → User 事件（借鉴 codex.nvim 的生命周期 autocmd 设计，
-- 数据源用 herdr 的 agent list —— agents-only 清单，免 pane label 匹配近似）
--
-- 单次 `herdr agent list`（每 tick 一个子进程）轮询 herdr 已注册的 agent，
-- 按 pane_id 跟踪 agent_status 变化并发出事件：
--   AIAgentWorking / AIAgentIdle / AIAgentBlocked
--   payload（event.data）= { tool = agent kind, pane_id, status, cwd }
-- 默认限定当前 workspace（HERDR_WORKSPACE_ID，与 herdr-nvim agents.lua 同约定），
-- 未设置时不过滤。可用于 "agent 完成 → 自动 format / lint / 关 pane" 之类的自动化。
--
-- 默认关闭（config.status_poll.enabled = false）：轮询会周期性起 herdr 子进程，
-- 按需开启；仅识别已知状态值，未知状态（unknown 等）不发事件。
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local timer = nil
local seen = {} -- pane_id -> 上次 agent_status（nil = 未识别 / 无状态）

local event_for = {
  working = "AIAgentWorking",
  idle = "AIAgentIdle",
  blocked = "AIAgentBlocked",
}

local function tick()
  local here = vim.env.HERDR_WORKSPACE_ID
  local list = utils.herdr_json("agent", "list")
  local agents = list and list.result and list.result.agents
  if type(agents) ~= "table" then
    return -- 单次失败忽略（herdr 重启等瞬态），下个 tick 再试
  end
  local alive = {}
  for _, a in ipairs(agents) do
    if not here or a.workspace_id == here then
      alive[a.pane_id] = true
      local status = a.agent_status
      if status ~= seen[a.pane_id] then
        seen[a.pane_id] = status
        local pattern = event_for[status]
        if pattern then
          utils.emit(pattern, {
            tool = a.agent,
            pane_id = a.pane_id,
            status = status,
            cwd = a.cwd or "",
          })
        end
      end
    end
  end
  for pane_id in pairs(seen) do
    if not alive[pane_id] then
      seen[pane_id] = nil -- pane 已关闭 / agent 已退出
    end
  end
end

function M.start()
  if timer then
    return
  end
  local interval = math.max(500, (config.options.status_poll or {}).interval_ms or 2000)
  timer = vim.fn.timer_start(interval, tick, { ["repeat"] = -1 })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.stop()
    end,
  })
end

function M.stop()
  if timer then
    vim.fn.timer_stop(timer)
    timer = nil
  end
end

-- 测试入口：手动驱动一次轮询（配合 utils.set_exec 注入假 agent list）
M._tick = tick

function M._reset()
  M.stop()
  seen = {}
end

return M
