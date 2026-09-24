# herder-agents.nvim

Control CLI coding agents (opencode, codex, qodercli, crush, omp, pi, hermes, …)
running in [Herdr](https://github.com/mildwind/herdr) panes — open/close panes,
send prompts from a popup, interrupt, switch tools, all from Neovim.

## Requirements

- [Herdr](https://github.com/mildwind/herdr) (`HERDR_ENV=1`) at runtime
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- Optional: fzf-lua (nicer pickers), nvim-web-devicons or mini.icons (file tree icons)

## Install

```lua
{
  "shaleix/herder-agents.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {
    keys = {
      toggle = "<leader>ho",
      input = "<leader>he",
      interrupt = "<leader>hx",
      new_session = "<leader>hc",
      history = "<leader>hh",
      switch = "<leader>ht",
      read_buffer = "<leader>hr",
      add_buffer = "<leader>ha",
      codex_model = "<leader>hm",
    },
  },
}
```

No keymaps are bound unless you pass `keys`. Each entry is a complete lhs;
use a table `{ "<leader>xx", mode = { "n", "i" } }` to override mode/desc.
Prefer your own mappings? Skip `keys` and call the API directly:

```lua
local ha = require("herder-agents")
vim.keymap.set("n", "<leader>ho", ha.toggle, { desc = "Toggle AI" })
```

## Keys (with the setup above)

| Binding | Action |
| --- | --- |
| `<leader>ho` | open/close the tool's herdr pane (toggles zoom when open) |
| `<leader>he` | prompt popup (visual mode prefills the selection as context) |
| `<leader>hx` | interrupt |
| `<leader>hc` | new session |
| `<leader>hh` | prompt history |
| `<leader>ht` | switch tool |
| `<leader>hr` / `<leader>ha` | add current buffer as read-only / editable attachment |
| `<leader>hm` | switch codex provider/model (codex only) |

In the prompt popup: `Ctrl+Enter` submit · `q`/`Esc` close (draft is kept) ·
`Ctrl+t` insert symbol path · `Ctrl+d` insert diagnostics · `dd`/`D` drop/clear attachments.

## Commands

- `:AIToggle [tool]` — toggle, callable from external scripts (worktree hooks)
- `:AISwitch [tool]` — switch tool (no argument cycles)

## Configuration

All options with comments live in [`lua/herder-agents/config.lua`](lua/herder-agents/config.lua). Highlights:

```lua
opts = {
  default_tool = "opencode",
  tools = { -- add any CLI agent here
    gemini = { title = " Gemini Chat " },
  },
  tool_cmds = { codex = "codex -m gpt-6-astra" }, -- per-project launch overrides
  split = { direction = "right", ratio = 0.55 },
  codex = { model_presets = { openai = { "gpt-6-astra", "gpt-5.6-sol" } } },
}
```

## API

`require("herder-agents")` returns: `toggle([tool])`, `input([draft])`, `interrupt()`,
`new_session()`, `history()`, `switch_tool()`, `read_buffer()`, `add_buffer()`,
`switch_codex_model()`, `send_prompt(tool, text)` (submit without the popup),
`current_session()` (attachments: `add_files` / `read_files` / `drop_files`).
`require("herder-agents.ui.common").dim(bufnr)` provides the float backdrop.
