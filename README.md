# herder-agents.nvim

Drive CLI coding agents (opencode / codex / qodercli / crush / omp / pi / hermes …)
running in [Herdr](https://github.com/mildwind/herdr) panes from inside Neovim,
with a unified prompt input popup, history, interrupt, and new-session actions.

Extracted from a local LazyVim config (`lua/config/keymap_ai_tool.lua` + `lua/ai_tools/`).
The tool registry is configurable and non-Herdr backends
(e.g. [agentic](https://github.com/agentic-labs/agentic.nvim)) can be attached via
`register_tool()`.

## Requirements

| Dependency | Required | Purpose |
| --- | --- | --- |
| [nui.nvim](https://github.com/MunifTanjim/nui.nvim) | yes | prompt popup / file tree / history view |
| [fzf-lua](https://github.com/ibhagwan/fzf-lua) | no | tool switcher, codex provider/model picker; falls back to `vim.ui.select` |
| nvim-web-devicons or mini.icons | no | file tree icons; omitted when absent |
| Herdr | runtime | pane split / zoom / send-text; requires `HERDR_ENV=1` |

## Installation (lazy.nvim)

```lua
{
  "shaleix/herder-agents.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {},
}
```

## Keymaps

**No keymaps are bound by default** — you bind them yourself. The table below is the
recommended set (the bindings used in the original config). Each action takes a complete
lhs in `keys`, so prefixes can be mixed freely:

| Recommended | Mode | Action | `keys` field |
| --- | --- | --- | --- |
| `<leader>ho` | n | Open/close the current tool's herdr pane; toggle pane zoom when it exists | `toggle` |
| `<leader>he` | n | Open the prompt input popup | `input` |
| `<leader>he` | x | Same, prefilling the draft with the selection as `@path (lines a-b)` + fence | `input` |
| `<leader>hx` | n/x | Interrupt the current tool (per-tool `interrupt_key`, default `ctrl+c`) | `interrupt` |
| `<leader>hc` | n/x | New session (`/clear` by default; `/new` for codex/opencode) | `new_session` |
| `<leader>hh` | n/x | Prompt history (grouped by cwd), `<CR>` refills the input popup | `history` |
| `<leader>ht` | n | Switch tool (fzf-lua / `vim.ui.select`) | `switch` |
| `<leader>hr` | n/x | Add current buffer as read-only context (non-herdr backends) | `read_buffer` |
| `<leader>ha` | n/x | Add current buffer as editable context (non-herdr backends) | `add_buffer` |
| `<leader>hs` | n/x | Restore a past session (agentic backend) | `select_session` |
| `<leader>hy` | n/x | Switch provider/agent (agentic backend) | `switch_provider` |
| `<leader>hm` | n/x | Switch codex provider/model (`/quit`, then `codex resume` restores the session) | `codex_model` |

### Option 1: the `keys` option of setup

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

### Option 2: bind manually via the API

```lua
local ha = require("herder-agents")
vim.keymap.set("n", "<leader>ho", ha.toggle, { desc = "Toggle AI" })
vim.keymap.set({ "n", "x" }, "<leader>he", function()
  ha.input(vim.fn.mode():find("^[vV\22]") and require("herder-agents.context").selection() or nil)
end, { desc = "AI Chat (prompt)" })
```

lazy.nvim users can also use a plugin `keys` spec (setup still runs, just without the
`keys` config option):

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

Inside the prompt popup:

| Key | Action |
| --- | --- |
| `Ctrl+Enter` / `Ctrl+s` | Submit (multi-line text is wrapped in bracketed paste) |
| `q` / `Esc` / `Ctrl+q` | Hide (the draft is kept and restored next time) |
| `Ctrl+t` | Insert a `Target position: file > symbol` line (LSP documentSymbol) |
| `Ctrl+d` | Insert current buffer diagnostics as editable text |
| `Ctrl+x` | Clear session file attachments |
| File tree: `dd` drop / `o` fold / `D` clear / `<CR>` open file | |

Codex drafts support a special first line `/queue <task>`: it is submitted with `tab`
instead of `enter`, triggering codex's task-queue feature.

## Commands

- `:AIToggle [tool]` — command version of the toggle action, for external scripts
  (e.g. worktree hooks); the optional argument picks the tool (`:AIToggle codex`)
- `:AISwitch [tool]` — cycle through tools without an argument, switch directly with one

The current tool is tracked in `vim.g.ai_tool` (readable/writable by external scripts).

## Configuration

All defaults (`tools` merges with the default table by key — adding a tool is one entry):

```lua
require("herder-agents").setup({
  default_tool = "opencode",
  autoread = true, -- auto-reload buffers changed by CLI tools in external panes

  tools = {
    -- cmd: pane launch command (defaults to the tool name)
    -- title: prompt popup title
    -- paste_wrap: wrap sent text in bracketed paste (enable for TUIs that submit line by line)
    -- interrupt_key: interrupt key (default ctrl+c)
    -- new_cmd: new-session command (default /clear)
    opencode = { title = " OpenCode Chat ", paste_wrap = true, interrupt_key = "esc", new_cmd = "/new" },
    qodercli = { title = " Qoder CLI Chat ", paste_wrap = true },
    crush = { title = " Crush Chat " },
    omp = { title = " Oh My Pi Chat ", interrupt_key = "esc" },
    pi = { title = " Pi Chat " },
    codex = { title = " Codex CLI Chat ", paste_wrap = true, new_cmd = "/new" },
    hermes = { title = " Hermes CLI Chat ", cmd = "hermes --tui" },
    -- adding a tool:
    -- mycli = { title = " My CLI Chat " },
  },

  -- per-project launch command overrides (equivalent to setting vim.g.ai_tool_cmd
  -- at runtime; vim.g takes precedence)
  tool_cmds = {},

  split = { direction = "right", ratio = 0.55 }, -- herdr split parameters
  history_file = "/tmp/cc_prompt_history.json", -- prompt history (keyed by cwd)
  chat_size = { width = 85, height = 35 }, -- input popup size
  icons = { folder = "", collapse_marks = { "", "" } },

  codex = { -- provider/model presets for <leader>hm
    home = "~/.codex",
    model_presets = {
      openai = { "gpt-6-astra", "gpt-5.6-sol" },
      ZAI = { "glm-5.3" },
      ["x-api"] = { "qwen3.8-max" },
    },
  },

  agentic = true, -- auto-register the backend when the agentic plugin is detected
  commands = { toggle = "AIToggle", switch = "AISwitch" },
  keys = {}, -- no keymaps by default; see the Keymaps section
})
```

### Value forms in `keys`

Each entry is a complete lhs and prefixes can be mixed freely:

```lua
require("herder-agents").setup({
  keys = {
    toggle = "<leader>ox", -- string: complete lhs, default modes (n for toggle)
    input = "<leader>ie", -- mixed prefixes (input defaults to n + x)
    interrupt = { -- table: full spec, override mode / desc
      "<leader>xx",
      mode = { "n", "i" },
      desc = "Stop the agent",
    },
    history = false, -- false: don't register
  },
})
```

## API

```lua
local ha = require("herder-agents")

ha.toggle("codex")            -- open/close a tool (nil = current tool)
ha.input("prefilled draft")   -- open the prompt popup
ha.interrupt()                -- interrupt
ha.new_session()              -- new session
ha.history()                  -- prompt history
ha.switch_tool()              -- switch tool via picker
ha.switch_codex_model()       -- codex provider/model switch
ha.read_buffer()              -- current buffer as read-only context (no-op for herdr backends)
ha.add_buffer()               -- current buffer as editable context
ha.select_session()           -- restore a past session (agentic backend)
ha.switch_provider()          -- switch provider/agent (agentic backend)
ha.register_tool(name, def)   -- register an external backend (see below)
ha.send_prompt(name, text)    -- send a prompt without the popup (submits with enter)
ha.current_session()          -- file attachment session (add_files / read_files / list_files / drop_files)
ha.api.add_current_buffer()   -- add current buffer as an editable attachment
ha.api.read_current_buffer()  -- add current buffer as a read-only attachment
```

Entry points for other config files that want this plugin's capabilities:

```lua
-- fzf-lua file picker ctrl-h: add files to the AI session
require("herder-agents").current_session():add_files(files)

-- fzf-lua diagnostics picker ctrl-h: send diagnostics to the current tool
require("herder-agents").send_prompt(vim.g.ai_tool, prompt)

-- full-screen backdrop for floats (e.g. neogit)
require("herder-agents.ui.common").dim(bufnr)
```

### Registering a non-herdr backend (agentic example)

The agentic plugin is auto-detected and registered when `agentic = true`. To register
custom backends manually:

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

Registered backends automatically show up in the tool switcher and `:AISwitch` completion.

## Migrating from the old config

1. Delete `lua/config/keymap_ai_tool.lua` and `lua/ai_tools/`
2. Remove the `require("config.keymap_ai_tool")` line from `lua/config/keymaps.lua`
3. In `plugins/fzf-lua.lua` / `plugins/neogit.lua`, change
   `require("ai_tools.ui.chat")` → `require("herder-agents.ui.chat")`,
   `require("ai_tools.sessions")` → `require("herder-agents.sessions")`,
   `require("ai_tools.ui.common")` → `require("herder-agents.ui.common")`
4. The prompt history path is unchanged (`/tmp/cc_prompt_history.json`), so history
   carries over as-is

## Tests

```sh
nvim --headless -u NONE --cmd "set rtp^=$(pwd)" -l test/smoke.lua
```
