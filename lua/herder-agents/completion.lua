-- prompt 输入弹窗（aider-input filetype）的 blink.cmp 补全注册。
--
-- blink.cmp 是可选依赖：未安装时静默跳过；blink 晚于本插件加载的场景由
-- FileType aider-input autocmd 兜底（弹窗打开时重试注册并预热缓存）。
-- 注册三个 source：
--   herder_skills  当前工具的 skills 补全（触发字符与数据源见 tools.<name>.skills
--                  与 skills.lua；completion/skills.lua 仅是 blink 适配层）
--   herder_agents  herdr:<pane_id> 提及补全（herdr agent list 的会话级 agent
--                  列表，见 agents.lua；completion/agents.lua 仅是 blink 适配层）
--   herder_path    复用 blink.cmp 内置 path source，按 cwd 补全文件路径
local M = {}

local registered = false

--- 注册 providers 与 filetype 映射（各步骤独立 pcall，单项失败不影响其余）
---@param blink table
---@return boolean 是否找到了可用的注册 API
local function register(blink)
  -- v1 为 add_provider，v2 起改名 add_source_provider，两者都兼容
  local add_provider = blink.add_source_provider or blink.add_provider
  if not add_provider then
    return false
  end

  pcall(add_provider, "herder_skills", {
    name = "HerderSkills",
    module = "herder-agents.completion.skills",
  })
  pcall(add_provider, "herder_agents", {
    name = "HerderAgents",
    module = "herder-agents.completion.agents",
  })
  pcall(add_provider, "herder_path", {
    name = "HerderPath",
    module = "blink.cmp.sources.path",
    opts = {
      get_cwd = function(_)
        return vim.fn.getcwd()
      end,
      trailing_slash = true,
      label_trailing_slash = true,
    },
  })
  pcall(blink.add_filetype_source, "aider-input", "herder_skills")
  pcall(blink.add_filetype_source, "aider-input", "herder_agents")
  pcall(blink.add_filetype_source, "aider-input", "herder_path")
  return true
end

function M.setup()
  local config = require("herder-agents.config")
  local opts = config.options.completion
  if not (opts and opts.enabled) then
    return
  end

  -- blink 晚于本插件加载时也能注册：弹窗打开（FileType aider-input）时重试
  -- 一次（setup 幂等），顺带预热 skill 与 herdr agent 列表缓存
  local group = vim.api.nvim_create_augroup("herder-agents-completion", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "aider-input",
    callback = function()
      M.setup()
      require("herder-agents.skills").warm()
      require("herder-agents.agents").warm()
    end,
  })

  if registered then
    return
  end

  local ok, blink = pcall(require, "blink.cmp")
  if not ok or not blink then
    return -- blink 未安装，等弹窗打开时的 autocmd 兜底重试
  end
  if register(blink) then
    registered = true
  end
end

return M
