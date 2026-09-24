-- codex provider/model 切换（<leader>hm）
--
-- 在 herdr 的 codex pane 上完成三步：
--   1. 记录会话：读取 herdr 上报的 codex 会话 id（pane 的 agent_session）
--   2. 选择目标：fzf 依次选择 provider 与 model
--      （候选来自 ~/.codex/config.toml、config.codex.model_presets 预设、
--       最近 30 天 rollout 实际用过的组合）
--   3. 重启：向 codex 发送 /quit 干净退出，等 pane 回到 shell 后执行
--      codex resume <session> -m <model> -c model_provider=<provider>
local M = {}

local utils = require("herder-agents.utils")
local chat = require("herder-agents.ui.chat")
local config = require("herder-agents.config")

local CUSTOM_MODEL_ENTRY = "✎ 自定义 model…"

local DEBUG = vim.env.CODEX_MODEL_DEBUG == "1"

local function codex_home()
  return vim.fn.expand(config.options.codex.home)
end

local function model_presets()
  return config.options.codex.model_presets
end

local function trim(value)
  return (value:gsub("^%s*(.-)%s*$", "%1"))
end

-- 轮询直到 cond(tick) 为真；超 max_ticks 次后以 false 结束（不阻塞 UI）
local function poll(cond, interval_ms, max_ticks, on_done)
  local tick = 0
  local function step()
    tick = tick + 1
    local ok, res = pcall(cond, tick)
    if DEBUG then
      print(string.format("[poll] tick=%d ok=%s res=%s", tick, tostring(ok), tostring(res)))
    end
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

-- herdr 的 agent 检测有秒级延迟（启动/退出后状态滞后），
-- 判断 codex 是否在运行用 pane process-info 的前台进程，不依赖 agent 集成状态
-- 返回 codex 前台进程信息表，没有则返回 nil
local function codex_foreground(pane_id)
  local out = vim.fn.system({ "herdr", "pane", "process-info", "--pane", pane_id })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok or not decoded.result then
    return nil
  end
  local procs = decoded.result.process_info and decoded.result.process_info.foreground_processes or {}
  for _, proc in ipairs(procs) do
    if proc.name == "codex" or proc.argv0 == "codex" then
      return proc
    end
  end
  return nil
end

local function codex_process_running(pane_id)
  return codex_foreground(pane_id) ~= nil
end

-- 解析 ~/.codex/config.toml：默认 provider/model 与 [model_providers.*] 键
-- （只为取键名做行扫描，无需完整 TOML 解析）
local function read_config_providers()
  local default_provider, default_model = "openai", nil
  local providers = {}
  local f = io.open(codex_home() .. "/config.toml", "r")
  if not f then
    return default_provider, default_model, providers
  end
  for line in f:lines() do
    local prov = line:match('^%s*model_provider%s*=%s*"([^"]+)"')
    if prov then
      default_provider = prov
    end
    -- 精确匹配键名 model，排除 model_provider / model_reasoning_effort 等
    local model = line:match('^%s*model%s*=%s*"([^"]+)"')
    if model then
      default_model = model
    end
    local p = line:match("^%s*%[model_providers%.([^%]]+)%]")
    if p then
      table.insert(providers, p)
    end
  end
  f:close()
  return default_provider, default_model, providers
end

-- 从最近 30 天 rollout 首行（session_meta）提取实际用过的 provider/model 组合；
-- 结果缓存 5 分钟，避免每次打开选择器都全量扫描
local discover_cache = { at = 0, map = {} }

local function discover_recent_models()
  if os.time() - discover_cache.at < 300 then
    return discover_cache.map
  end
  local map = {}
  discover_cache = { at = os.time(), map = map }

  local sessions_dir = codex_home() .. "/sessions"
  if vim.fn.isdirectory(sessions_dir) == 0 then
    return map
  end
  -- 只读每个文件第一行，从中抠出 model_provider 与 model（provenance）两个字段
  local awk =
    [[FNR==1 { p=""; m=""; if (match($0,/"model_provider":"[^"]*"/)) { p=substr($0,RSTART,RLENGTH); sub(/^"model_provider":"/,"",p); sub(/"$/,"",p) } if (match($0,/"model":"[^"]*"/)) { m=substr($0,RSTART,RLENGTH); sub(/^"model":"/,"",m); sub(/"$/,"",m) } if (p!="" && m!="") print p "\t" m }]]
  local out = vim.fn.systemlist({
    "find",
    sessions_dir,
    "-name",
    "*.jsonl",
    "-mtime",
    "30",
    "-exec",
    "awk",
    awk,
    "{}",
    "+",
  })
  if vim.v.shell_error ~= 0 then
    return map
  end
  for _, line in ipairs(out or {}) do
    local provider, model = line:match("^(%S+)\t(%S+)$")
    if provider and model then
      map[provider] = map[provider] or {}
      if not vim.tbl_contains(map[provider], model) then
        table.insert(map[provider], model)
      end
    end
  end
  return map
end

local function model_entries(provider, default_provider, default_model, discovered)
  local entries, seen = {}, {}
  local function add(model)
    if model and model ~= "" and not seen[model] then
      seen[model] = true
      table.insert(entries, model)
    end
  end
  if provider == default_provider then
    add(default_model)
  end
  for _, model in ipairs(discovered[provider] or {}) do
    add(model)
  end
  for _, model in ipairs(model_presets()[provider] or {}) do
    add(model)
  end
  table.insert(entries, CUSTOM_MODEL_ENTRY)
  return entries
end

local function pick(entries, prompt, on_select)
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entries, {
      prompt = prompt,
      winopts = {
        width = 0.35,
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

local function restart_args(session_id, provider, model)
  -- 命令由 pane run 逐字输入到 pane 内的 shell 执行；
  -- 值用单引号包裹，-c 的值内层用双引号保证被按 TOML 字符串解析
  local args = { "codex" }
  if session_id then
    table.insert(args, "resume")
    table.insert(args, session_id)
  end
  table.insert(args, "-m")
  table.insert(args, "'" .. model .. "'")
  table.insert(args, "-c")
  table.insert(args, string.format("'model_provider=\"%s\"'", provider))
  return args
end

-- codex 退出时会在 pane 里打印 "codex resume <id>" 提示；
-- herdr 未上报会话 id 时从这里兜底抓取
local function extract_resume_hint(pane_id)
  local out = vim.fn.system({ "herdr", "pane", "read", pane_id, "--lines", "12" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out:match("codex resume ([%x%-]+)") or nil
end

local function launch(pane_id, session_id, provider, model)
  -- herdr 未上报会话 id 时（如 codex 已退回 shell），从退出提示兜底抓取
  if not session_id then
    session_id = extract_resume_hint(pane_id)
  end
  -- /quit 退出后 shell 上可能残留半行输入（kitty 键盘协议残留字符），先清行
  chat.herdr_exec("pane", "send-keys", pane_id, "ctrl+c")
  local args = { "herdr", "pane", "run", pane_id }
  vim.list_extend(args, restart_args(session_id, provider, model))
  vim.fn.system(args)
  -- 就绪判断同样用进程级信息：新 codex 进程的 argv 里带上了目标 model 才算成功，
  -- 避免 agent 检测残留（旧实例退出后 pane.agent 短期内仍为 codex）造成假成功
  poll(
    function()
      local proc = codex_foreground(pane_id)
      return proc ~= nil and proc.argv ~= nil and vim.tbl_contains(proc.argv, model)
    end,
    500,
    60,
    function(ok)
      local target = provider .. " / " .. model
      if ok then
        utils.info("codex 已切换到 " .. target .. (session_id and " 并恢复会话" or ""))
      else
        utils.warn("重启命令已发送，但未能确认 codex 就绪，请检查 pane")
      end
    end
  )
end

local function agent_gone(pane_id)
  -- 仅以 codex 前台进程为准（pane 被关闭时 herdr 调用失败同样视为已退出；
  -- 异常场景由 launch 后的就绪轮询兜底提示）
  return not codex_process_running(pane_id)
end

local function quit_codex(pane_id, on_done)
  local function send_quit()
    chat.herdr_exec("pane", "send-text", pane_id, "/quit")
    chat.herdr_exec("pane", "send-keys", pane_id, "enter")
  end
  send_quit()
  -- codex 退出需等待 MCP/hook 清理，网络不佳时可达数十秒
  poll(
    function(tick)
      if agent_gone(pane_id) then
        return true
      end
      -- TUI 初始化期间（启动转圈）/quit 会被吞掉，10s 后重发一次
      if tick == 20 then
        send_quit()
      end
      return false
    end,
    500,
    60,
    function(ok)
      if ok then
        on_done()
        return
      end
      -- /quit 未生效（例如任务运行中弹了确认框），ctrl+c 兜底再等一轮
      chat.herdr_exec("pane", "send-keys", pane_id, "ctrl+c")
      poll(
        function()
          return agent_gone(pane_id)
        end,
        500,
        30,
        function(ok2)
          if ok2 then
            on_done()
          else
            utils.err("codex 未能退出，已放弃切换；请手动检查 pane")
          end
        end
      )
    end
  )
end

local function restart(pane_id, session_id, provider, model)
  if provider:match("['\"%s;`]") or model:match("['\"%s;`]") then
    utils.err("provider/model 含有非法字符: " .. provider .. " / " .. model)
    return
  end
  utils.info("codex 切换到 " .. provider .. " / " .. model .. " 中，等待退出重启…")

  local function after_exit()
    launch(pane_id, session_id, provider, model)
  end

  if codex_process_running(pane_id) then
    quit_codex(pane_id, after_exit)
  else
    launch(pane_id, session_id, provider, model)
  end
end

--- 切换 codex 的 provider/model：记录会话 → 选择 → 重启并恢复会话
function M.switch()
  if vim.env.HERDR_ENV ~= "1" then
    utils.err("codex model 切换需要在 Herdr 中使用")
    return
  end
  local pane = chat.find_tool_pane("codex")
  if not pane then
    return
  end
  if pane.agent == "codex" and (pane.agent_status == "working" or pane.agent_status == "blocked") then
    utils.warn(
      "codex 正在 "
        .. pane.agent_status
        .. "，请先等待完成或用 "
        .. config.key_hint("interrupt", "<leader>hx")
        .. " 中断后再切换"
    )
    return
  end
  local session_id = pane.agent_session and pane.agent_session.value or nil

  local default_provider, default_model, config_providers = read_config_providers()
  local discovered = discover_recent_models()

  local providers, seen = {}, {}
  local function add_provider(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      table.insert(providers, p)
    end
  end
  add_provider(default_provider)
  for _, p in ipairs(config_providers) do
    add_provider(p)
  end
  for p in pairs(discovered) do
    add_provider(p)
  end
  for p in pairs(model_presets()) do
    add_provider(p)
  end

  local display = {}
  for i, p in ipairs(providers) do
    display[i] = (p == default_provider) and (p .. "  (默认)") or p
  end

  pick(display, "Codex Provider> ", function(chosen)
    if not chosen then
      return
    end
    local provider = chosen:gsub("%s*%(默认%)$", "")
    local models = model_entries(provider, default_provider, default_model, discovered)
    pick(models, "Codex Model (" .. provider .. ")> ", function(model)
      if not model then
        return
      end
      if model == CUSTOM_MODEL_ENTRY then
        vim.ui.input({ prompt = "自定义 model id: " }, function(input)
          input = input and trim(input) or ""
          if input == "" then
            utils.warn("未输入 model，已取消")
            return
          end
          restart(pane.pane_id, session_id, provider, input)
        end)
        return
      end
      restart(pane.pane_id, session_id, provider, model)
    end)
  end)
end

return M
