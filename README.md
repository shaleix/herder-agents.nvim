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
      note = "<leader>hn",
      notes_view = "<leader>hN",
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
| `<leader>hn` | add a note at the cursor line (visual mode: selection range) |
| `<leader>hN` | notes popup: review/toggle notes + Extra Prompt, `<CR>` send / `<C-a>` append |
| `<leader>hm` | switch codex provider/model (codex only) |

In the prompt popup: `Ctrl+Enter` submit · `q`/`Esc` close (draft is kept) ·
`Ctrl+t` insert symbol path · `Ctrl+d` insert diagnostics · `dd`/`D` drop/clear attachments.

## Notes

Annotate code inline, then review and send the annotations from a dedicated popup.

- `<leader>hn` in normal mode notes the cursor line; in visual mode it notes the
  selected line range. An **inline input box** opens right below that line: the
  following content is pushed down by virtual lines (no line numbers, the buffer
  is never modified) and you type in place, right where you are looking. The thin
  border shows a `✎ note` title (top-left) and the key hints (bottom-right), with
  its left edge aligned to the code. `Ctrl+Enter`/`Ctrl+s` saves, `Esc`/`q`
  cancels; the gap collapses either way. Triggering on a position that already
  has a note re-opens it **prefilled for editing** (`✎ edit note` title) — saving
  updates it in place instead of adding a duplicate.
- Each note is marked in the source buffer with a gutter sign (`✎`) and an
  end-of-line preview. Markers follow the code as you edit (extmark-based), so the
  note stays anchored to the right lines.
- `<leader>hN` opens the **notes popup** (independent of the chat popup): all notes
  listed and **checked by default** (cursor starts on the first note, normal
  mode), a blank line, then an `Extra Prompt: - ` line at the bottom (same
  buffer) for an extra instruction to send along with the notes.
  `<Space>`/`x` toggles a note · `dd` deletes it · `q`/`Esc` closes.
- Two ways to submit:
  - `<CR>` — **send now**: text goes to the agent pane followed by Enter.
  - `<C-a>` — **append only**: the same text lands in the agent's input box
    *without* Enter, so you can keep editing there and submit manually.
- Submitted text (extra prompt becomes a final `- ` bullet):

  ```
  Notes:
  - @src/foo.lua (line 70): handle the nil case
  - @src/foo.lua (lines 10-20): check the edge cases
  - <extra prompt>
  ```

- Notes are session-scoped (in memory, like file attachments) and cleared on restart.

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
  icons = { note = "✎" }, -- gutter sign for notes ("" disables the sign)
  notes = { preview_width = 40 }, -- end-of-line note preview width
}
```

## API

`require("herder-agents")` returns: `toggle([tool])`, `input([draft])`, `interrupt()`,
`new_session()`, `history()`, `switch_tool()`, `read_buffer()`, `add_buffer()`,
`add_note()`, `notes_view()`, `switch_codex_model()`, `send_prompt(tool, text)` (submit without the popup),
`current_session()` (attachments: `add_files` / `read_files` / `drop_files`).
`require("herder-agents.notes")` is the session note store (`add` / `list` / `checked` /
`toggle` / `remove` / `clear`).
`require("herder-agents.ui.chat").append_tool_prompt(tool, text)` puts text into the
agent's input box without pressing Enter.
`require("herder-agents.ui.common").dim(bufnr)` provides the float backdrop.
