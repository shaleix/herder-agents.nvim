-- LLM adapter（ADR-0002）：extraction 用的可插拔提问接口，唯一实现收口于此。
-- 不依赖任何 LLM 插件（llm.nvim 系是 FIM ghost-text 补全、无任意 prompt 的
-- Lua API；`llm` CLI 是 Python 外部依赖），内置默认为 OpenAI 兼容 HTTP
--（DeepSeek 开箱，DEEPSEEK_API_KEY）：
--   POST {base_url}/chat/completions，body 含 response_format = { type = "json_object" }
-- 经 utils.exec_async_to_file 包 sh -c curl（Authorization header、-m 超时、
-- 输出走临时文件 —— 与 skills api 同一惯例：CLI 大响应经管道偶发截断，文件
-- 重定向同步写始终完整，且超时 SIGKILL 命中真实进程、回调准时）。
--
-- 注入惯例（仿 utils.set_exec）：
--   - M.set_adapter(fn)：运行期 / 测试注入，传 nil 恢复内置实现
--   - config.llm.adapter：配置式覆盖（社区 adapter 后补入口，见 ADR-0002）
-- adapter 约定：fn(opts, cb)，opts = { system, user, timeout_ms }；
-- 成功 cb(table, nil)（content 已解码为 table），失败 cb(nil, err)。
--
-- 内置实现的成功路径：HTTP JSON → choices[1].message.content → vim.json.decode
-- → table；失败（curl 非零 / 超时 / 响应坏 JSON / content 缺失或坏 JSON）
-- 回 nil + 错误描述。
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")

local injected_adapter = nil -- 测试 / 运行期注入（优先于 config.llm.adapter）

--- 测试注入：覆盖 LLM adapter（传 nil 恢复内置实现）
function M.set_adapter(fn)
  injected_adapter = fn
end

-- 当前生效的 adapter（注入 > 配置）
local function current_adapter()
  return injected_adapter or (config.options.llm or {}).adapter
end

--- 内置 HTTP 通道的 API key 检查：缺失时返回错误描述（可直接展示）；
--- 配置了自定义 adapter 时不适用（返回 nil = 不缺）
function M.api_key_error()
  if current_adapter() then
    return nil
  end
  local env_name = (config.options.llm or {}).api_key_env or "DEEPSEEK_API_KEY"
  local key = vim.env[env_name]
  if not key or key == "" then
    return "缺少 API key：请设置环境变量 " .. env_name
  end
  return nil
end

-- 内置 OpenAI 兼容实现（见文件头）
local function builtin_ask(opts, cb)
  local key_err = M.api_key_error()
  if key_err then
    cb(nil, key_err)
    return
  end
  local cfg = config.options.llm or {}
  local env_name = cfg.api_key_env or "DEEPSEEK_API_KEY"
  local base_url = (cfg.base_url or "https://api.deepseek.com"):gsub("/+$", "")
  local timeout_ms = opts.timeout_ms or cfg.timeout_ms or 30000
  local body = vim.json.encode({
    model = cfg.model or "deepseek-chat",
    temperature = cfg.temperature or 0,
    response_format = { type = "json_object" },
    messages = {
      { role = "system", content = opts.system },
      { role = "user", content = opts.user },
    },
  })
  local argv = {
    "curl",
    "-sS",
    "-X",
    "POST",
    base_url .. "/chat/completions",
    "-H",
    "Authorization: Bearer " .. vim.env[env_name],
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
    -- curl 自身的应用层超时（秒，向上取整）；exec_async_to_file 另有 SIGKILL 兜底
    "-m",
    tostring(math.max(1, math.ceil(timeout_ms / 1000))),
  }
  utils.exec_async_to_file(argv, function(r)
    if r.code ~= 0 then
      cb(nil, ("curl 失败（exit %d）%s"):format(r.code, r.stderr ~= "" and ": " .. r.stderr or ""))
      return
    end
    if r.stdout == "" then
      cb(nil, "LLM 端点返回空响应（可能超时被杀）")
      return
    end
    local ok, http = pcall(vim.json.decode, r.stdout)
    if not ok or type(http) ~= "table" then
      cb(nil, "LLM 端点返回非 JSON 响应: " .. tostring(r.stdout):sub(1, 200))
      return
    end
    local choice = http.choices and http.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) ~= "string" or content == "" then
      cb(nil, "LLM 响应缺少 message.content")
      return
    end
    local ok_content, obj = pcall(vim.json.decode, content)
    if not ok_content or type(obj) ~= "table" then
      cb(nil, "message.content 不是合法 JSON: " .. content:sub(1, 200))
      return
    end
    cb(obj, nil)
  end, timeout_ms)
end

--- 向 LLM 提问。opts: { system, user, timeout_ms? }
--- cb(obj, err)：成功 obj 为解码后的 table；失败 obj 为 nil、err 为错误描述
function M.ask(opts, cb)
  local fn = current_adapter()
  if fn then
    fn(opts, cb)
    return
  end
  builtin_ask(opts, cb)
end

return M
