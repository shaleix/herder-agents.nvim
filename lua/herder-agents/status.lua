-- agent 状态轮询 → User 事件（借鉴 codex.nvim 的生命周期 autocmd 设计）
--
-- 单次 `herdr pane list`（每 tick 一个子进程）轮询本插件注册的工具 pane，
-- 按 pane_id 跟踪 agent_status 变化并发出事件：
--   AIAgentWorking / AIAgentIdle / AIAgentBlocked
--   payload（event.data）= { tool = 工具名, pane_id = pane id, status = 新状态 }
-- 可用于 "agent 完成 → 自动 format / lint / 关 pane" 之类的自动化。
--
-- 默认关闭（config.status_poll.enabled = false）：轮询会周期性起 herdr 子进程，
-- 按需开启；仅识别 agent_status 的状态值变化，未知状态不发事件。
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local timer = nil
local leave_aucmd = nil -- VimLeavePre handle：stop 时注销，避免 start/stop 循环累积重复 autocmd

local seen = {} -- pane_id -> 上次 agent_status（nil = 未识别 / 无状态）

local event_for = {
  working = "AIAgentWorking",
  idle = "AIAgentIdle",
  blocked = "AIAgentBlocked",
}

local function tick()
  local list = utils.herdr_json("pane", "list")
  local panes = list and list.result and list.result.panes
  if not panes then
    return -- 单次失败忽略（herdr 重启等瞬态），下个 tick 再试
  end
  local alive = {}
  for _, pane in ipairs(panes) do
    local tool = pane.label
    -- 只跟踪本插件注册的工具 pane（其他 pane 的 agent 不属于本插件管理）
    if tool and config.options.tools[tool] then
      alive[pane.pane_id] = true
      local status = pane.agent_status
      if status ~= seen[pane.pane_id] then
        seen[pane.pane_id] = status
        local pattern = event_for[status]
        if pattern then
          utils.emit(pattern, { tool = tool, pane_id = pane.pane_id, status = status })
        end
      end
    end
  end
  for pane_id in pairs(seen) do
    if not alive[pane_id] then
      seen[pane_id] = nil -- pane 已关闭
    end
  end
end

function M.start()
  if timer then
    return
  end
  local interval = math.max(500, (config.options.status_poll or {}).interval_ms or 2000)
  timer = vim.fn.timer_start(interval, tick, { ["repeat"] = -1 })
  leave_aucmd = vim.api.nvim_create_autocmd("VimLeavePre", {
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
  if leave_aucmd then
    vim.api.nvim_del_autocmd(leave_aucmd)
    leave_aucmd = nil
  end
end

function M._reset()
  M.stop()
  seen = {}
end

return M
