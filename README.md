# herder-agents.nvim

在 Neovim 中驱动跑在 [Herdr](https://github.com/mildwind/herdr) pane 里的 CLI 编码 agent
（opencode / codex / qodercli / crush / omp / pi / hermes …），
并提供统一的 prompt 输入弹窗、历史、中断、新会话等操作。

从本地 LazyVim 配置（`lua/config/keymap_ai_tool.lua` + `lua/ai_tools/`）抽象而来，
工具注册表可配置，并可通过 `register_tool()` 接入非 herdr 后端（如 [agentic](https://github.com/agentic-labs/agentic.nvim)）。

## 依赖

| 依赖 | 必需 | 用途 |
| --- | --- | --- |
| [nui.nvim](https://github.com/MunifTanjim/nui.nvim) | 是 | prompt 弹窗 / 文件树 / 历史视图 |
| [fzf-lua](https://github.com/ibhagwan/fzf-lua) | 否 | 工具切换器、codex provider/model 选择；缺失时回退 `vim.ui.select` |
| nvim-web-devicons 或 mini.icons | 否 | 文件树图标；缺失时不显示 |
| Herdr | 运行时 | pane 分屏 / zoom / send-text；`HERDR_ENV=1` 时才可用 |

## 安装（lazy.nvim）

```lua
{
  "shaleix/herder-agents.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {},
}
```

本地开发用 `dir` 指向仓库即可：

```lua
{
  dir = "~/workerspace/herder-agents.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {},
}
```

## 快捷键

**默认不绑定任何快捷键**，由用户自己绑定。下表是推荐绑定（即原 LazyVim 配置里的一套），每个功能在 `keys` 中独立配置**完整 lhs**，可任意混用前缀：

| 推荐绑定 | 模式 | 功能 | keys 字段 |
| --- | --- | --- | --- |
| `<leader>ho` | n | 打开/关闭当前工具的 herdr pane；已存在时切换 pane zoom | `toggle` |
| `<leader>he` | n | 打开 prompt 输入弹窗 | `input` |
| `<leader>he` | x | 同上，选区格式化为 `@path (lines a-b)` + fence 预填草稿 | `input` |
| `<leader>hx` | n/x | 中断当前工具（按工具的 `interrupt_key`，默认 `ctrl+c`） | `interrupt` |
| `<leader>hc` | n/x | 新会话（默认 `/clear`，codex/opencode 为 `/new`） | `new_session` |
| `<leader>hh` | n/x | prompt 历史（按 cwd 分组），回车回填到输入弹窗 | `history` |
| `<leader>ht` | n | 切换工具（fzf-lua / `vim.ui.select`） | `switch` |
| `<leader>hr` | n/x | 当前缓冲区加入只读上下文（非 herdr 后端） | `read_buffer` |
| `<leader>ha` | n/x | 当前缓冲区加入可编辑上下文（非 herdr 后端） | `add_buffer` |
| `<leader>hs` | n/x | 恢复历史会话（agentic 后端） | `select_session` |
| `<leader>hy` | n/x | 切换 provider/agent（agentic 后端） | `switch_provider` |
| `<leader>hm` | n/x | 切换 codex 的 provider/model（`/quit` 后 `codex resume` 恢复会话） | `codex_model` |

### 绑定方式一：setup 的 keys 配置项

```lua
require("herder-agents").setup({
  keys = {
    toggle = "<leader>ho",
    input = "<leader>he",
    interrupt = "<leader>hx",
    new_session = "<leader>hc",
    history = "<leader>hh",
    switch = "<leader>ht",
    read_buffer = "<leader>hr",
    add_buffer = "<leader>ha",
    switch_provider = "<leader>hy",
    codex_model = "<leader>hm",
  },
})
```

### 绑定方式二：自行 vim.keymap.set 调 API

```lua
local ha = require("herder-agents")
vim.keymap.set("n", "<leader>ho", ha.toggle, { desc = "Toggle AI" })
vim.keymap.set({ "n", "x" }, "<leader>he", function()
  ha.input(vim.fn.mode():find("^[vV\22]") and require("herder-agents.context").selection() or nil)
end, { desc = "AI Chat (prompt)" })
```

lazy.nvim 用户也可以用插件的 `keys` spec（此时 setup 照常执行，只是不传 keys 配置项）：

```lua
return {
  "shaleix/herder-agents.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {},
  keys = {
    { "<leader>ho", "<cmd>lua require('herder-agents').toggle()<cr>", desc = "Toggle AI" },
    { "<leader>ht", "<cmd>lua require('herder-agents').switch_tool()<cr>", desc = "Switch AI tool" },
  },
}
```

prompt 弹窗内：

| 按键 | 功能 |
| --- | --- |
| `Ctrl+Enter` / `Ctrl+s` | 提交（多行用 bracketed paste 包裹发送） |
| `q` / `Esc` / `Ctrl+q` | 收起（草稿保留，下次打开恢复） |
| `Ctrl+t` | 插入 `Target position: 文件 > 符号` 行（LSP documentSymbol） |
| `Ctrl+d` | 把当前缓冲区诊断作为可编辑文本插入草稿 |
| `Ctrl+x` | 清空会话文件附件 |
| 文件树：`dd` 丢弃 / `o` 折叠 / `D` 清空 / `<CR>` 打开文件 | |

codex 草稿专用语法：首行 `/queue <任务>` 提交时以 `tab` 结尾，触发 codex 的任务排队。

## 命令

- `:AIToggle [tool]` — `<leader>ho` 的命令版，供外部脚本（如 worktree_hook.sh）调用；
  可选参数指定工具（`:AIToggle codex`）
- `:AISwitch [tool]` — 无参数循环切换，带参数直接切换（`:AISwitch codex`）

当前工具状态在 `vim.g.ai_tool`（外部脚本可读写）。

## 配置

全部默认值（`tools` 与默认表按 key 合并，新增工具只需加一项）：

```lua
require("herder-agents").setup({
  default_tool = "opencode",
  autoread = true, -- CLI 工具在外部 pane 改文件后自动重载 buffer

  tools = {
    -- cmd: pane 启动命令（默认与 name 相同）
    -- title: prompt 弹窗标题
    -- paste_wrap: bracketed paste 包裹（TUI 支持时开启，防多行被逐行提交）
    -- interrupt_key: 中断按键（默认 ctrl+c）
    -- new_cmd: 新会话命令（默认 /clear）
    opencode = { title = " OpenCode Chat ", paste_wrap = true, interrupt_key = "esc", new_cmd = "/new" },
    qodercli = { title = " Qoder CLI Chat ", paste_wrap = true },
    crush = { title = " Crush Chat " },
    omp = { title = " Oh My Pi Chat ", interrupt_key = "esc" },
    pi = { title = " Pi Chat " },
    codex = { title = " Codex CLI Chat ", paste_wrap = true, new_cmd = "/new" },
    hermes = { title = " Hermes CLI Chat ", cmd = "hermes --tui" },
    -- 新增工具示例：
    -- mycli = { title = " My CLI Chat " },
  },

  -- 项目级启动命令覆盖（等价于运行期设 vim.g.ai_tool_cmd，vim.g 优先）
  tool_cmds = {},

  split = { direction = "right", ratio = 0.55 }, -- herdr 分屏参数
  history_file = "/tmp/cc_prompt_history.json", -- prompt 历史（按 cwd 分键）
  chat_size = { width = 85, height = 35 }, -- 输入弹窗尺寸
  icons = { folder = "", collapse_marks = { "", "" } },

  codex = { -- <leader>hm 的 provider/model 预设
    home = "~/.codex",
    model_presets = {
      openai = { "gpt-6-astra", "gpt-5.6-sol" },
      ZAI = { "glm-5.3" },
      ["x-api"] = { "qwen3.8-max" },
    },
  },

  agentic = true, -- 探测到 agentic 插件时自动注册后端
  commands = { toggle = "AIToggle", switch = "AISwitch" },
  keys = {}, -- 默认不绑定任何快捷键；绑定方式见上「快捷键」一节
})
```

### keys 配置项的值形式

`keys` 的每项独立配置完整 lhs，前缀可任意混用：

```lua
require("herder-agents").setup({
  keys = {
    toggle = "<leader>ox", -- string：完整 lhs，mode 用默认值（toggle 为 n）
    input = "<leader>ie", -- 不同前缀混用（input 默认 n + x）
    interrupt = { -- table：完整 spec，可覆盖 mode / desc
      "<leader>xx",
      mode = { "n", "i" },
      desc = "Stop the agent",
    },
    history = false, -- false：不注册
  },
})
```

## API

```lua
local ha = require("herder-agents")

ha.toggle("codex")            -- 打开/关闭指定工具（nil 用当前工具）
ha.input("预填内容")           -- 打开 prompt 弹窗
ha.interrupt()                -- 中断
ha.new_session()              -- 新会话
ha.history()                  -- prompt 历史
ha.switch_tool()              -- 选择器切换工具
ha.switch_codex_model()       -- codex provider/model 切换
ha.read_buffer()              -- 当前缓冲区加入只读上下文（herdr 后端为 no-op）
ha.add_buffer()               -- 当前缓冲区加入可编辑上下文
ha.select_session()           -- 恢复历史会话（agentic 后端）
ha.switch_provider()          -- 切换 provider/agent（agentic 后端）
ha.register_tool(name, def)   -- 注册外部后端（见下）
ha.send_prompt(name, text)    -- 不经弹窗直接发送 prompt（回车提交）
ha.current_session()          -- 文件附件会话（add_files / read_files / list_files / drop_files）
ha.api.add_current_buffer()   -- 当前缓冲区加入可编辑附件
ha.api.read_current_buffer()  -- 当前缓冲区加入只读附件
```

其他配置引用本插件能力的入口：

```lua
-- fzf-lua 文件选择器 ctrl-h：加入 AI 会话附件
require("herder-agents").current_session():add_files(files)

-- fzf-lua 诊断选择器 ctrl-h：把诊断发送给当前工具
require("herder-agents").send_prompt(vim.g.ai_tool, prompt)

-- neogit 等浮窗的全屏遮罩
require("herder-agents.ui.common").dim(bufnr)
```

### 注册非 herdr 后端（以 agentic 为例）

agentic 插件默认已自动适配（`agentic = true` 时探测注册）。手工注册自定义后端：

```lua
local ha = require("herder-agents")
ha.register_tool("agentic", {
  toggle = function() require("agentic").toggle() end,
  input = function() require("agentic").open_prompt_float({ focus_prompt = true }) end,
  history = function() require("agentic").open_prompt_history() end,
  interrupt = function() require("agentic").stop_generation() end,
  new = function() require("agentic").new_session() end,
  select_session = function() require("agentic").restore_session() end,
  switch_provider = function() require("agentic").switch_provider() end,
  read_buffer = function()
    require("agentic").add_files_to_context({ files = { vim.fn.expand("%:p") }, focus_prompt = false })
  end,
  add_buffer = function() require("agentic").add_file({ focus_prompt = false }) end,
})
```

注册后自动进入 `<leader>ht` 切换列表与 `:AISwitch` 补全。

## 从旧配置迁移

1. 删除 `lua/config/keymap_ai_tool.lua` 与 `lua/ai_tools/`（或保留 `lua/ai_tools/`
   只做转发：`return require("herder-agents")`）
2. `config/keymaps.lua` 里 require keymap_ai_tool 的一行去掉
3. `plugins/fzf-lua.lua`、`plugins/neogit.lua` 中的
   `require("ai_tools.ui.chat")` → `require("herder-agents.ui.chat")`，
   `require("ai_tools.sessions")` → `require("herder-agents.sessions")`，
   `require("ai_tools.ui.common")` → `require("herder-agents.ui.common")`
4. prompt 历史文件路径不变（`/tmp/cc_prompt_history.json`），迁移后历史直接可用

## 测试

```sh
nvim --headless -u NONE --cmd "set rtp^=$(pwd)" -l test/smoke.lua
```
