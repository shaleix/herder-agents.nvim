-- herdr agent 列表获取层（`herdr agent list`，当前 herdr 会话、跨 workspace）：
-- completion/agents.lua 只是 blink.cmp 适配层，异步/缓存/降级策略全部收口在本模块。
--
-- 候选语义：只认 pane_id（agent name 可选且可能缺失，仅进展示/过滤文本）。
-- 规范化条目 { pane_id, kind, status, name, title, cwd, tab_id, workspace_id,
-- workspace }，缺 pane_id 的条目跳过、保持源顺序。workspace = workspace 显示名：
-- 每次刷新并行拉 `herdr workspace list` 做 id→名 join（label 缺失回落
-- workspace_id；workspace 拉取失败保留旧名表，不拖垮本轮 agent 刷新）。
--
-- 缓存策略（单键、无配置项；ttl 由 _ttl_ms 供给，测试可覆写）：
--   - 缓存新鲜（age < ttl）：同步回调缓存
--   - 缓存过期但有缓存：先回调旧列表，同时后台刷新（in_flight 时跳过重复刷新）
--   - 无缓存：回调挂起（pending），首拉完成后统一 flush，成功失败都 flush
-- 任何失败静默降级（旧列表或 {}）——补全绝不报错、绝不阻塞、绝不告警。
-- 非 herdr 环境（HERDR_ENV ~= "1"）直接回空列表，不发起 CLI。
local M = {}

local utils = require("herder-agents.utils")

local uv = vim.uv or vim.loop

-- 缓存 ttl（ms）：测试可覆写（同 skills._api_timeout_ms 的注入约定）
M._ttl_ms = 5000

local cache = nil -- { items, time }（time 为 uv.hrtime() 纳秒）
local pending = {} -- 首拉未完成时挂起的回调列表
local in_flight = false
local workspace_labels = {} -- workspace_id → 显示名（label 缺失回落 workspace_id）

-- 缓存是否新鲜
local function fresh()
  return cache ~= nil and cache.items ~= nil and (uv.hrtime() - cache.time) / 1e6 < M._ttl_ms
end

--- list(on_done)：回调规范化条目数组。新鲜缓存同步回调；过期先回旧列表 + 后台
--- 刷新；无缓存挂起回调，完成后统一 flush。任何失败静默降级（旧列表或 {}）
---@param on_done fun(entries: table)
function M.list(on_done)
  -- 非 herdr 环境没有 agent 列表可言：不发起 CLI，直接空列表
  if vim.env.HERDR_ENV ~= "1" then
    if on_done then
      pcall(on_done, {})
    end
    return
  end

  if fresh() then
    if on_done then
      pcall(on_done, cache.items) -- 新鲜：同步回缓存
    end
    return
  end

  if cache and cache.items then
    if on_done then
      pcall(on_done, cache.items) -- 过期：先回旧列表，同时后台刷新
    end
  elseif on_done then
    table.insert(pending, on_done) -- 首拉未完成：挂起，完成后统一 flush
  end

  if not in_flight then
    in_flight = true
    -- 完成/失败统一走 finish：agent list 失败（非零退出/非 JSON/缺 agents/执行器
    -- 抛异常）不动旧缓存，仍 flush 挂起回调（回旧列表或 {}）；workspace list
    -- 失败只保留旧 label 表，绝不拖垮本轮 agent 刷新
    local finish = function(agent_res, ws_res)
      -- workspace id→名 join：仅成功响应才更新 label 表（失败沿用旧表 —— 条目的
      -- workspace 字段届时回落 workspace_id，展示层无需另做兜底）
      if
        type(ws_res) == "table"
        and ws_res.code == 0
        and type(ws_res.stdout) == "string"
        and ws_res.stdout ~= ""
      then
        local ok_ws, decoded_ws = pcall(vim.json.decode, ws_res.stdout)
        if
          ok_ws
          and type(decoded_ws) == "table"
          and type(decoded_ws.result) == "table"
          and type(decoded_ws.result.workspaces) == "table"
        then
          local labels = {}
          for _, w in ipairs(decoded_ws.result.workspaces) do
            if type(w) == "table" and type(w.workspace_id) == "string" and w.workspace_id ~= "" then
              labels[w.workspace_id] = (type(w.label) == "string" and w.label ~= "" and w.label) or w.workspace_id
            end
          end
          workspace_labels = labels
        end
      end

      agent_res = type(agent_res) == "table" and agent_res or {}
      local entries = nil
      if agent_res.code == 0 and type(agent_res.stdout) == "string" and agent_res.stdout ~= "" then
        local ok, decoded = pcall(vim.json.decode, agent_res.stdout)
        if
          ok
          and type(decoded) == "table"
          and type(decoded.result) == "table"
          and type(decoded.result.agents) == "table"
        then
          entries = {}
          for _, a in ipairs(decoded.result.agents) do
            if type(a) == "table" and type(a.pane_id) == "string" and a.pane_id ~= "" then
              local ws = workspace_labels[a.workspace_id]
              table.insert(entries, {
                pane_id = a.pane_id,
                kind = a.agent,
                status = a.agent_status,
                name = a.name,
                title = a.terminal_title_stripped or a.terminal_title,
                cwd = a.cwd,
                tab_id = a.tab_id,
                workspace_id = a.workspace_id,
                -- 显示名：label join 命中优先，否则回落 workspace_id（可 nil）
                workspace = (ws and ws ~= "" and ws) or a.workspace_id,
              })
            end
          end
        end
      end
      if entries ~= nil then
        cache = { items = entries, time = uv.hrtime() }
      end
      in_flight = false
      -- 先摘出再回调：回调里若再触发 list（重入），新挂起的回调不会被本轮清空
      local cbs = pending
      pending = {}
      local items = cache and cache.items or {}
      for _, cb in ipairs(cbs) do
        pcall(cb, items)
      end
    end

    -- 两条 CLI 并行（agent list 数据 + workspace list join），双边到齐才 finish。
    -- 各自 pcall 包住：注入执行器抛异常也按一次完成计，join 不会挂死（单边只
    -- 计一次完成，防执行器"先回调又抛异常"的重复计数）
    local agent_res, ws_res = nil, nil
    local remaining = 2
    local side = function()
      local fired = false
      return function()
        if fired then
          return
        end
        fired = true
        remaining = remaining - 1
        if remaining == 0 then
          finish(agent_res, ws_res)
        end
      end
    end
    local join_agent, join_ws = side(), side()
    local ok_a, err_a = pcall(utils.exec_async, { "herdr", "agent", "list" }, function(r)
      agent_res = r
      join_agent()
    end)
    if not ok_a and agent_res == nil then
      agent_res = { code = -1, stdout = "", stderr = tostring(err_a) }
      join_agent()
    end
    local ok_w, err_w = pcall(utils.exec_async, { "herdr", "workspace", "list" }, function(r)
      ws_res = r
      join_ws()
    end)
    if not ok_w and ws_res == nil then
      ws_res = { code = -1, stdout = "", stderr = tostring(err_w) }
      join_ws()
    end
  end
end

--- 预热（弹窗打开时调用，fire-and-forget）：仅在无缓存/已过期时触发拉取
function M.warm()
  if fresh() then
    return
  end
  M.list(function() end)
end

--- 输入 buffer 绑定的 agent pane_id（vim.b[buf].pane_id，chat 弹窗与行内
--- prompt 输入在打开时写入）。无绑定 / buffer 失效时返回 nil —— 补全路径
--- 零额外 CLI（当前 agent 的判定只读 buffer 变量）
---@param buf integer
---@return string|nil
function M.current_pane_id(buf)
  local ok, id = pcall(vim.api.nvim_buf_get_var, buf, "pane_id")
  if ok and type(id) == "string" and id ~= "" then
    return id
  end
  return nil
end

--- 测试注入：清空缓存/挂起回调/in_flight 标记/workspace 名表（与 skills._reset 同款约定）
function M._reset()
  cache = nil
  pending = {}
  in_flight = false
  workspace_labels = {}
end

return M
