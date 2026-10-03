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
      add_buffer = "<leader>ha",
      note = "<leader>hn",
      line_prompt = "<leader>hp",
      notes_view = "<leader>hr",
      switch_mode = "<leader>hM",
      model = "<leader>hm",
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
| `<leader>ht` | switch tool — closes the current agent and restarts the new one in the same herdr pane (`switch_replace`; interrupt a working agent first). Before the relaunch the pane's terminal modes are reset and the input line cleared: an agent that exits without restoring them (kitty keyboard push, SGR mouse reporting, bracketed paste, hidden cursor) leaves the shell encoding real key/mouse events into garbage (`5:1u9;5:1uopencode` → command not found), so the launch command would glue onto the residue and never start |
| `<leader>ha` | add current buffer as editable attachment (read-only via `read_buffer()` API) |
| `<leader>hn` | add a note at the cursor line (visual mode: selection range) |
| `<leader>hp` | inline prompt at the cursor line / selection — `Ctrl+Enter` sends it straight to the agent with a `Target: @file (line N)` locator |
| `<leader>hr` | notes popup: review/toggle notes + Extra Prompt, `<CR>` send / `<C-a>` append |
| `<leader>hM` | switch the agent's mode via herdr (per-tool `mode_switch`: opencode v2 `Shift+Tab` cycles build/plan, codex `/approvals` + focus jump) |
| `<leader>hm` | switch model — unified flow for every tool: flatten the two-level `tools.<name>.models` config (`provider → models`) into one `provider/model` picker, then apply it per tool: opencode switches **in place** via `opencode api post /api/session/{id}/model` (same call as the in-pane `ctrl+x m` dialog — no restart, works while the agent is running, `#variant` suffixes map to the API `variant` field); tools with a `model_resume` template gracefully quit and relaunch in the same pane (codex: `codex resume <session> -m …`; session ids come from `herdr agent_session` / `opencode api session.list` matched against the pane title). `models` is opt-in; tools without `models` fall back to the `model_switch` key directive (opencode's is the in-pane `ctrl+x m` dialog) |

In the prompt popup: `Ctrl+Enter` submit · `q`/`Esc` close (draft is kept) ·
`Ctrl+t` insert symbol path · `Ctrl+d` insert diagnostics · `dd`/`D` drop/clear attachments.

## Notes

Annotate code inline, then review and send the annotations from a dedicated popup.

- `<leader>hn` in normal mode notes the cursor line; in visual mode it notes the
  selected line range. An **inline input box** opens right below that line: the
  following content is pushed down by virtual lines (no line numbers, the buffer
  is never modified) and you type in place, right where you are looking. The thin
  border shows a `󰆈 note` title (top-left) and the key hints (bottom-right), with
  its left edge aligned to the code. `Ctrl+Enter` saves (same submit key as the
  chat popup), `Esc`/`q`
  cancels; the gap collapses either way. Triggering on a position that already
  has a note re-opens it **prefilled for editing** (`󰆈 edit note` title) — saving
  updates it in place instead of adding a duplicate.
- `<leader>hp` reuses the **same inline input box** for one-off instructions:
  type a prompt at the cursor line (or visual selection) and press `Ctrl+Enter` —
  it goes straight to the current agent as `<prompt>` + a `Target: @file (line N)`
  locator. Nothing is stored; if the agent pane is missing the box stays open for
  a retry.
- Each note is marked in the source buffer with a gutter sign (comment bubble,
  configurable via `icons.note`) and an
  end-of-line preview. Markers follow the code as you edit (extmark-based), so the
  note stays anchored to the right lines.
- `<leader>hr` opens the **notes popup** (independent of the chat popup): all notes
  listed and **checked by default** (cursor starts on the first note, normal
  mode), a blank line, then an `Extra Prompt: - ` line at the bottom (same
  buffer) for an extra instruction to send along with the notes.
  `<Space>`/`x` toggles a note · `dd` deletes it · `q`/`Esc` closes.
  After a successful submit, the sent (checked) notes are removed automatically
  (buffer markers included); unchecked notes stay for later.
- Two ways to submit:
  - `<CR>` — **send now**: text goes to the agent pane followed by Enter.
  - `<C-a>` — **append only**: the same text lands in the agent's input box
    *without* Enter, so you can keep editing there and submit manually.
- Submitted text — the header tells the agent these are review comments to act
  on (customizable via `notes.submit_header`), and the extra prompt becomes a
  final `- ` bullet:

  ```
  Please address these code review comments:
  - @src/foo.lua (line 70): handle the nil case
  - @src/foo.lua (lines 10-20): check the edge cases
  - <extra prompt>
  ```

- Notes are session-scoped (in memory, like file attachments) and cleared on restart.

## Commands

- `:AIToggle [tool]` — toggle, callable from external scripts (worktree hooks)
- `:AISwitch [tool]` — switch tool (no argument cycles); like `<leader>ht`, replaces the agent pane
- `:AIDropQueue` — drop prompts queued while no agent was ready

## Prompt delivery

Prompts travel through a small delivery queue modeled after codex.nvim's
`pending_sends` design, preferring herdr's own agent integration (usage
borrowed from herdr-nvim):

- When the target pane is a herdr-registered agent, submission goes through
  `herdr agent prompt`: the server presses Enter for you, understands the
  agent state machine, and refuses when the agent is blocked. Waiting uses
  `herdr agent wait --until idle/working` (server-side, chunked timeouts)
  instead of client-side polling.
- Unregistered panes and custom tools fall back to the text channel:
  `pane send-text` with per-tool bracketed-paste encoding plus a submit key.
  codex `/queue` (tab submit) and append-only sends always use the text
  channel. Set `delivery.agent_channel = false` to force the text channel
  everywhere.
- A prompt is sent only once its pane is ready (agent status `idle`/`working`,
  or a foreground process for the text channel), re-checked after a short
  settle delay that skips the TUI initialization window — including prompts
  submitted while the agent already looks ready. Until then it is queued and
  delivered automatically once the agent is up. Startup screens no longer eat
  your text.
- While prompts are queued (or settling), readiness polling spawns a
  short-lived `herdr` subprocess per tick (`delivery.poll_interval_ms`).
- Delivery success is judged by the `herdr` CLI exit code. A failed
  `send-text`/`agent prompt` no longer reports success: the chat-popup draft,
  the inline prompt gap, and the notes are kept for retry.
- Long waits warn once (`delivery.warn_after_ms`) but keep waiting;
  `:AIDropQueue` drops everything queued; queues are dropped automatically
  when the pane disappears.
- The chat popup, inline prompts, and the notes popup are bound to the pane
  they were opened against. If that pane is closed or replaced while you type
  (`:AISwitch`, codex model switching reuse panes), submission is refused
  instead of silently continuing a different session.
- Checked notes are removed only after the delivery actually succeeds.
- Visual selection context larger than `context.max_lines` / `context.max_bytes`
  is rejected with a warning instead of being pasted.

Caveat: interactive startup dialogs *inside* the pane (e.g. the codex trust
prompt) cannot be detected — answer them manually; queued prompts send once
the agent is up.

## Events

User autocmds (payloads in `event.data`):

| Pattern | When | data |
| --- | --- | --- |
| `AIPromptQueued` | a prompt enters the queue | tool, pane_id, pending |
| `AIPromptSent` | a prompt was delivered | tool, pane_id, submitted, queued |
| `AIDeliveryFailed` | delivery failed / queue dropped | tool, pane_id, queued, reason |
| `AIAgentWorking` / `AIAgentIdle` / `AIAgentBlocked` | agent status change (needs `status_poll.enabled = true`) | tool, pane_id, status, cwd |

Example: react when the agent finishes (opt-in poller):

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "AIAgentIdle",
  callback = function(event)
    if event.data.tool == "codex" then
      -- agent finished: check buffers, run a formatter, ...
    end
  end,
})
```

## Configuration

All options with comments live in [`lua/herder-agents/config.lua`](lua/herder-agents/config.lua). Highlights:

```lua
opts = {
  default_tool = "opencode",
  tools = { -- add any CLI agent here
    gemini = { title = " Gemini Chat " },
    -- mode_switch drives <leader>hM (keys = herdr send-keys, cmd = text +
    -- Enter, focus = jump herdr focus to the pane afterwards);
    -- opencode/codex ship sensible defaults
    claude = { title = " Claude Chat ", mode_switch = { keys = { "shift+tab" } } },
    -- model switching (<leader>hm>): two-level models config flattened into a
    -- single provider/model picker, then applied per tool. opencode switches
    -- IN PLACE via the session model API (same call as the in-pane ctrl+x m
    -- dialog — no restart, works while the agent is running; `#variant`
    -- suffixes map to the API variant field). Tools with a model_resume
    -- template quit + relaunch instead (placeholders {session} {provider}
    -- {model}; session ids come from session_source: "codex" = herdr
    -- agent_session, "opencode" = api session.list matched against the pane
    -- title). models is opt-in; by default <leader>hm uses the in-pane dialog
    -- fallback (ctrl+x m + focus jump).
    opencode = {
      models = {
        ["zhipuai-coding-plan"] = { "glm-5.3", "glm-5.3#high", "glm-5.3-flash" },
        opencode = { "mimo-v2.6-flash-free" },
      },
    },
    codex = {
      models = { openai = { "gpt-6-astra", "gpt-5.6-sol" }, ZAI = { "glm-5.3" } },
    },
  },
  tool_cmds = { codex = "codex -m gpt-6-astra" }, -- per-project launch overrides
  split = { direction = "right", ratio = 0.55 },
  switch_replace = true, -- switching tools closes the old agent & restarts the new one in its pane
  -- prompt delivery queue (see "Prompt delivery"); agent_channel = false
  -- forces the plain send-text path; enabled = false restores fire-and-forget
  -- sending (exit-code checks stay)
  delivery = {
    agent_channel = true,
    poll_interval_ms = 300,
    settle_ms = 300,
    warn_after_ms = 5000,
  },
  -- selection context limits: rejected beyond, never truncated
  context = { max_lines = 500, max_bytes = 65536 },
  -- opt-in agent status poller -> AIAgentWorking/Idle/Blocked events
  status_poll = { enabled = false, interval_ms = 2000 },
  icons = { note = "󰆈" }, -- gutter sign for notes (nf-md-comment_text; "" disables the sign)
  notes = {
    preview_width = 40, -- end-of-line note preview width
    submit_header = "Please address these code review comments:", -- header of the block sent to the agent
  },
}
```

## API

`require("herder-agents")` returns: `toggle([tool])`, `input([draft])`, `interrupt()`,
`new_session()`, `history()`, `switch_tool()`, `read_buffer()`, `add_buffer()`,
`add_note()`, `notes_view()`, `switch_mode()`, `switch_model()`,
`send_prompt(tool, text[, on_done])` (submit without the popup; `on_done(ok, queued)`
fires after the actual delivery),
`current_session()` (attachments: `add_files` / `read_files` / `drop_files`).
`require("herder-agents.notes")` is the session note store (`add` / `list` / `checked` /
`toggle` / `remove` / `clear`).
`require("herder-agents.ui.chat").append_tool_prompt(tool, text)` puts text into the
agent's input box without pressing Enter.
`require("herder-agents.delivery")` is the prompt transport: `deliver(pane_id, tool, text,
opts)` (queue-aware send), `drop_all()`, `check_binding(name, bound_pane_id, pane)`,
`pane_agent_running(pane_id)`.
`require("herder-agents.status")` starts/stops the agent status poller.
`require("herder-agents.ui.common").dim(bufnr)` provides the float backdrop.
