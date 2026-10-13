-- herdr pane 适配器（按工具名驱动的 pane 机器，自 ui/chat 拆出）：
-- 查找 / 启动切换 / 中断 / 新会话 / agent 替换（退出 → 同 pane 重启）的统一入口。
-- 依赖单向：chat → panes ← model_restart，init/tools 直接调本模块，
-- 任何模块都不再为 pane 操作 require ui/chat
local M = {}

local utils = require("herder-agents.utils")
local config = require("herder-agents.config")
local delivery = require("herder-agents.delivery")

-- 兼容 LuaJIT(5.1) 全局 unpack 与 5.2+ 的 table.unpack；
-- 0.12 已移除 vim.list_unpack，勿再使用
local unpack = unpack or table.unpack

local function herdr_panes()
  local list = utils.herdr_json("pane", "list")
  return (list and list.result and list.result.panes) or {}
end

local function current_herdr_tab_id()
  local current = utils.herdr_json("pane", "current")
  local current_pane = current and current.result and current.result.pane
  return current_pane and current_pane.tab_id, current_pane
end

-- pane 的 cwd 与当前 nvim 工作目录是否同一目录（resolve 抹平 symlink 差异）
local function pane_cwd_matches(pane)
  if type(pane.cwd) ~= "string" or pane.cwd == "" then
    return false
  end
  return vim.fn.resolve(pane.cwd) == vim.fn.resolve(vim.fn.getcwd())
end

-- 按工具名找 pane，三级匹配（toggle 找不到时会另 split 新实例，故尽量收编
-- 既有 pane，避免同仓库连开多个 agent）：
-- ① 当前 tab 内 label == 工具名 —— 插件 split 后 rename 过的 pane（原语义，
--   cwd 不参与；①命中时 zoom-toggle 行为保持不变）
-- ② 任意 tab 中 cwd 与当前目录一致且 label == 工具名 —— 跨 tab 复用同名 pane
-- ③ 任意 tab 中 cwd 一致且 pane.agent == 工具名 —— herdr agent 集成的进程级
--   检测（pane run 后秒内出现，无需 session），收编手工开 / 被改成自定义
--   label（工单号等）的同仓库 agent pane；该级内有 agent_session 的优先
local function find_tool_pane(name)
  local tab_id = current_herdr_tab_id()
  local by_label, by_session, by_agent = nil, nil, nil
  for _, p in ipairs(herdr_panes()) do
    if p.label == name and p.tab_id == tab_id then
      return p
    end
    if pane_cwd_matches(p) then
      if not by_label and p.label == name then
        by_label = p
      end
      if p.agent == name then
        if not by_session and p.agent_session then
          by_session = p
        end
        by_agent = by_agent or p
      end
    end
  end
  return by_label or by_session or by_agent
end

local function toggle_cli_in_herdr_pane(cmd, label)
  local tab_id, current_pane = current_herdr_tab_id()
  if not current_pane then
    utils.err("herdr pane current failed; are you inside Herdr?")
    return
  end

  local existing = find_tool_pane(label)
  if existing then
    if existing.tab_id == tab_id and existing.label == label then
      -- 当前 tab 的插件 pane（label 命中）：保持 zoom-toggle 语义
      local layout = utils.herdr_json("pane", "layout", "--current")
      local zoomed = layout and layout.result and layout.result.layout and layout.result.layout.zoomed
      if zoomed then
        utils.herdr_ok("pane", "zoom", "--off", "--current")
      else
        utils.herdr_ok("pane", "zoom", "--on", "--pane", current_pane.pane_id)
      end
      return
    end
    -- 既有 pane 在其他 tab，或是同 cwd 的自定义 label/手工开的 agent pane：
    -- 切过去并放大该 pane，不重复 split 第二个实例
    --（zoom 是 tab 内布局概念，跨 tab 只能切焦点）
    utils.herdr_ok("tab", "focus", existing.tab_id)
    utils.herdr_ok("pane", "zoom", "--on", "--pane", existing.pane_id)
    return
  end

  local split = utils.herdr_json(
    "pane",
    "split",
    "--current",
    "--direction",
    config.options.split.direction,
    "--ratio",
    tostring(config.options.split.ratio),
    "--no-focus",
    "--cwd",
    vim.fn.getcwd()
  )
  local pane_id = split and split.result and split.result.pane and split.result.pane.pane_id
  if not pane_id then
    utils.err("herdr pane split failed")
    return
  end
  local args = { "pane", "run", pane_id }
  for _, part in ipairs(vim.split(cmd, " ", { plain = true })) do
    if part ~= "" then
      table.insert(args, part)
    end
  end
  utils.herdr_ok(unpack(args))
  utils.herdr_ok("pane", "rename", pane_id, label)
end

local function cli_pane(name)
  local pane = find_tool_pane(name)
  if not pane then
    local hint = config.key_hint("toggle", "<leader>ho")
    utils.err(name .. " pane not found; use " .. hint .. " first")
  end
  return pane
end

local function herdr_cli_toggle(name, cmd)
  if vim.env.HERDR_ENV ~= "1" then
    utils.err(name .. " mode requires Herdr")
    return
  end
  toggle_cli_in_herdr_pane(cmd or name, name)
end

-- 中断按键序列的逐键间隔：TUI 需把每个 Esc 解析成独立按键事件，同一次写入的
-- esc esc 会被输入解析器合并（alt+esc / 转义序列），间隔发送等价于人工连按
local INTERRUPT_KEY_DELAY_MS = 150

-- key 为单键字符串或键序列 table；序列逐键间隔发送（opencode 两段式 Esc 中断：
-- 第一次 Esc 只进入 "ESC again to interrupt" 待确认态，第二次才真正中断）
local function herdr_cli_interrupt(name, key)
  local pane = cli_pane(name)
  if not pane then
    return
  end
  local keys = type(key) == "table" and key or { key }
  local function send(i)
    utils.herdr_json("pane", "send-keys", pane.pane_id, keys[i])
    if i < #keys then
      vim.defer_fn(function()
        send(i + 1)
      end, INTERRUPT_KEY_DELAY_MS)
    end
  end
  send(1)
end

local function herdr_cli_new_session(name, tool)
  local pane = cli_pane(name)
  if pane then
    -- agent 未就绪（刚重启等）时排队，避免 /new 落进 shell
    delivery.deliver(pane.pane_id, name, tool.new_cmd or "/clear", {
      submit_key = "enter",
      paste_wrap = tool.paste_wrap == true,
    })
  end
end

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

-- 统一重启序列（收敛原 replace_tool 的 launch_new 与 model_restart 的 launch）：
-- ctrl+c 清行 → 终端复位载荷 → +300ms 后补一次 ctrl+c → pane run →（可选改名）
-- → 前台就绪轮询（统一 500ms × 60）→ on_ready(err)：成功为 nil，失败给原因。
-- cmd：字符串按单个参数发给 pane run（与直接下发命令等价）；table 逐元素展开
--（model_restart 的 model_resume 模板替换产物）
function M.relaunch(pane_id, cmd, opts, on_ready)
  opts = opts or {}
  utils.herdr_json("pane", "send-keys", pane_id, "ctrl+c") -- 清掉 shell 残留输入
  -- 旧 agent（如 codex）进程退出后，其 TUI 清场仍可能迟到向 pane 输出一段特殊
  -- 字符，第一次 ctrl+c 赶在它们落进 shell 输入行之前；此外 TUI 可能遗留终端
  -- 私有模式（kitty keyboard / SGR 鼠标上报 / bracketed paste / 隐藏光标），
  -- herdr 仍会把真实按键与鼠标事件编码成转义序列持续污染输入行
  -- （"5:1u9;5:1uopencode" → command not found）。这些模式只能由 pane 内
  -- 进程写 tty 输出侧复位 —— 先让 shell 执行一条 printf 复位载荷
  --（自带前导 \r，与被污染行原子隔离），再启动新 agent
  utils.reset_pane_terminal(pane_id)
  vim.defer_fn(function()
    -- 复位生效后不再产生新的事件污染；printf 执行前排队迟到的事件再补一次
    -- ctrl+c 清行，保证启动命令落在一个干净的提示符上
    utils.herdr_json("pane", "send-keys", pane_id, "ctrl+c")
    local args = { "pane", "run", pane_id }
    if type(cmd) == "table" then
      vim.list_extend(args, cmd)
    else
      table.insert(args, cmd)
    end
    utils.herdr_json(unpack(args))
    if opts.rename then
      utils.herdr_json("pane", "rename", pane_id, opts.rename)
    end
    -- 就绪判断以前台进程为准（herdr 的 agent 集成检测有秒级延迟）
    poll(
      function()
        return delivery.pane_agent_running(pane_id) == true
      end,
      500,
      60,
      function(ok)
        on_ready(ok and nil or "pane 前台进程未确认就绪（启动命令可能未生效）")
      end
    )
  end, 300)
end

-- 当前 tab 内按 label 找工具 pane；tab 内没有时按「同 cwd 的 label 命中 /
-- herdr agent 检测命中」跨 tab 复用（见 find_tool_pane 三级匹配）；找不到时提示
function M.find(name)
  return cli_pane(name)
end

-- 静默查找（找不到不提示，返回 nil）；草稿绑定、发送前校验用。
-- 与 find 同规则（find_tool_pane 三级匹配）
function M.lookup(name)
  return find_tool_pane(name)
end

function M.toggle(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_toggle(name, config.tool_cmd(name))
  end
end

-- ---------------------------------------------------------------------------
-- 宽度 toggle（:HerdrShrinkToggle / keys.shrink_toggle）：
-- nvim pane 与当前工具 agent pane 左右相邻时，把两者的分界在「当前比例」与
-- toggle_ratio 间来回切。amount 语义为共同 split 的比例差（herdr resize
-- --amount 实测为 0~1 比例，且服务端自带最小宽度 clamp）；比例基准 =
-- nvim 宽 / (nvim + agent 宽)（相邻即共同 split 的两个直接子节点）。
-- 收窄前的基准比例存 vim.g（按 nvim pane id 绑定）；nvim 重启后遗忘，
-- 首按把当前比例记为基准再收窄。
-- ---------------------------------------------------------------------------
local SHRINK_STATE = "herd_shrink_state"

local function current_tab_layout()
  local res = utils.herdr_json("pane", "layout", "--current")
  return res and res.result and res.result.layout
end

local function pane_rect_in(layout, pane_id)
  for _, p in ipairs(layout.panes or {}) do
    if p.pane_id == pane_id then
      return p.rect
    end
  end
  return nil
end

-- 左右相邻判定：共享一条竖直分界。agent 在 nvim 右侧返回 "right"，左侧返回
-- "left"；上下布局 / 嵌套不相邻返回 nil（不支持，提示手动调整，避免推错
-- 边界压到无关 pane）
local function adjacent_side(nvim_rect, agent_rect)
  if not (nvim_rect and agent_rect) then
    return nil
  end
  local same_band = nvim_rect.y < agent_rect.y + agent_rect.height and agent_rect.y < nvim_rect.y + nvim_rect.height
  if not same_band then
    return nil
  end
  if nvim_rect.x + nvim_rect.width == agent_rect.x then
    return "right"
  end
  if agent_rect.x + agent_rect.width == nvim_rect.x then
    return "left"
  end
  return nil
end

function M.shrink_toggle(name)
  if vim.env.HERDR_ENV ~= "1" then
    utils.err(name .. " 宽度切换需要在 Herdr 中使用")
    return
  end
  local tab_id, current_pane = current_herdr_tab_id()
  if not current_pane then
    utils.err("herdr pane current failed; are you inside Herdr?")
    return
  end
  local agent = find_tool_pane(name)
  if not agent or agent.tab_id ~= tab_id then
    utils.err(name .. " pane not found; use " .. config.key_hint("toggle", "<leader>ho") .. " first")
    return
  end
  local layout = current_tab_layout()
  if not layout then
    utils.err("herdr pane layout failed")
    return
  end
  if layout.zoomed then
    utils.warn("当前 pane 处于 zoom 全屏，先退出 zoom 再切换宽度")
    return
  end

  local nvim_rect = pane_rect_in(layout, current_pane.pane_id)
  local agent_rect = pane_rect_in(layout, agent.pane_id)
  local side = adjacent_side(nvim_rect, agent_rect)
  if not side then
    utils.warn(name .. " pane 与 nvim pane 不相邻（上下/嵌套布局），请手动调整宽度")
    return
  end

  local target = config.options.toggle_ratio
  local current = nvim_rect.width / (nvim_rect.width + agent_rect.width)
  local state = vim.g[SHRINK_STATE]
  -- 已收窄（当前 ≈ toggle_ratio 且有基准）→ 恢复；否则记基准并收窄。
  -- 手动改过宽度（两者皆不匹配）按收窄处理，基准更新为手调值
  local restoring = type(state) == "table"
    and state.pane == current_pane.pane_id
    and type(state.baseline) == "number"
    and math.abs(current - target) <= 0.02
  if restoring then
    target = state.baseline
  else
    vim.g[SHRINK_STATE] = { pane = current_pane.pane_id, baseline = current }
  end

  local delta = target - current
  if math.abs(delta) < 0.005 then
    if restoring then
      vim.g[SHRINK_STATE] = nil
    end
    utils.info("已在目标宽度")
    return
  end

  -- agent 在右：nvim 收窄（delta<0）= agent 左边界左移；agent 在左镜像
  local direction
  if side == "right" then
    direction = delta < 0 and "left" or "right"
  else
    direction = delta < 0 and "right" or "left"
  end
  local res = utils.herdr_json(
    "pane",
    "resize",
    "--pane",
    agent.pane_id,
    "--direction",
    direction,
    "--amount",
    string.format("%.4f", math.abs(delta))
  )
  local changed = res and res.result and res.result.resize and res.result.resize.changed
  if changed == false then
    utils.info("宽度已到边界，未变化")
    return
  end
  if restoring then
    vim.g[SHRINK_STATE] = nil
    utils.info(string.format("nvim pane 宽度已恢复（%d%%）", math.floor(target * 100 + 0.5)))
  else
    utils.info(string.format("nvim pane 已收窄到 %d%%", math.floor(target * 100 + 0.5)))
  end
end

function M.interrupt(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_interrupt(name, tool.interrupt_key or "ctrl+c")
  end
end

function M.new_session(name)
  local tool = config.options.tools[name]
  if tool then
    herdr_cli_new_session(name, tool)
  end
end

-- 切换 agent 的前置检查：旧工具 agent 正在 working/blocked 时先中断再切
--（与 codex model 切换的守卫一致；无 pane / 非 herdr 环境直接放行）
function M.can_replace(old_name)
  if vim.env.HERDR_ENV ~= "1" or not old_name then
    return true
  end
  local pane = find_tool_pane(old_name)
  if pane and (pane.agent_status == "working" or pane.agent_status == "blocked") then
    utils.warn(
      old_name
        .. " 正在 "
        .. pane.agent_status
        .. "，请先用 "
        .. config.key_hint("interrupt", "<leader>hx")
        .. " 中断后再切换"
    )
    return false
  end
  return true
end

-- 切换 agent（类似 codex model 切换的"退出 → 同 pane 重启"流程）：
-- 1. 新工具已有 pane → 直接关闭旧工具 pane（herdr 会一并结束其进程）
-- 2. 否则优雅退出旧 pane 的 agent（TERM 前台进程组，卡住则 KILL），
--    pane 回到 shell 后再补发 ctrl+c 清掉迟到的 TUI 清场残留，
--    在同一 pane 启动新工具并改名（herdr 布局原位保持）
-- 3. 旧工具无 pane → 新工具也无 pane 时按 split 流程新建（同 toggle）
function M.replace(old_name, new_name)
  if vim.env.HERDR_ENV ~= "1" then
    utils.err("agent 替换切换需要在 Herdr 中使用")
    return false
  end
  local new_cmd = config.tool_cmd(new_name) or new_name
  -- 新旧工具 pane 都按共享规则解析（当前 tab 优先，其次同 cwd 跨 tab），
  -- 与 find/interrupt 等入口看到的是同一个 pane
  local new_pane = find_tool_pane(new_name)
  local old_pane = old_name and find_tool_pane(old_name) or nil

  if not old_pane then
    if not new_pane then
      toggle_cli_in_herdr_pane(new_cmd, new_name)
    end
    return true
  end

  if new_pane then
    utils.herdr_json("pane", "close", old_pane.pane_id)
    utils.info("已关闭 " .. old_name .. " pane，当前 agent: " .. new_name)
    return true
  end

  local pane_id = old_pane.pane_id
  utils.info("切换 agent：" .. old_name .. " → " .. new_name .. "，等待旧 agent 退出…")

  local function launch_new()
    M.relaunch(pane_id, new_cmd, { rename = new_name }, function(err)
      if err then
        utils.warn("启动命令已发送，但未能确认 " .. new_name .. " 就绪，请检查 pane")
      else
        utils.info("已切换到 " .. new_name)
      end
    end)
  end

  local running, fgid = delivery.pane_agent_running(pane_id)
  if not running then
    launch_new() -- 旧 agent 已退出（pane 里是 shell），直接重启新的
    return true
  end

  -- 优雅退出：TERM 前台进程组（负 pid = 进程组，shell 不在该组内不受影响）
  if fgid then
    vim.fn.system({ "kill", "-TERM", "-" .. tostring(fgid) })
  end
  poll(
    function()
      local r = delivery.pane_agent_running(pane_id)
      return r == false or r == nil
    end,
    400,
    25,
    function(ok)
      if ok then
        launch_new()
        return
      end
      -- TERM 未生效 → KILL 强杀再等一轮
      local _, fg2 = delivery.pane_agent_running(pane_id)
      if fg2 then
        vim.fn.system({ "kill", "-KILL", "-" .. tostring(fg2) })
      end
      poll(
        function()
          local r = delivery.pane_agent_running(pane_id)
          return r == false or r == nil
        end,
        400,
        15,
        function(ok2)
          if ok2 then
            launch_new()
          else
            utils.err(old_name .. " 未能退出，已放弃切换；请手动检查 pane")
          end
        end
      )
    end
  )
  return true
end

return M
