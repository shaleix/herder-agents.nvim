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
      shrink_toggle = "<leader>h<",
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
| `<leader>h<` | width toggle: switch nvim's share of its owning split's content width (the whole tab width in the standard layout) between `toggle_ratio` (default 32%, nvim shrunk) and the default split ratio `split.ratio` (default 55%), regardless of how many panes the tab has (a stacked agent column or panes in between are fine — the nvim boundary is what moves); stateless — currently ≈ `toggle_ratio` restores the default ratio, anything else snaps back to `toggle_ratio`; zoomed, vertical-only layouts, or a lone nvim pane are refused with a hint — herdr clamps the minimum width |
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
- `:HerdrShrinkToggle` — width toggle: switch between `toggle_ratio` and the default split ratio (same as `keys.shrink_toggle`)
- `:AIDropQueue` — drop prompts queued while no agent was ready
- `:AIQuestion` — extract the agent's pending question into an answer form (see below)
- `:AIQuestionDev [file]` — dev: drive the question form from a local file or the current buffer (see below)

## Agent question form

When an agent stops to ask you something (choices, confirmations), `:AIQuestion`
turns the pane output back into an interactive form. The popup opens
immediately as a loading skeleton (staged text: capturing → extracting →
read-more round N/M → retry, with a spinner; `esc` cancels and discards the
late LLM result) and morphs in place into the form once extraction finishes:

1. Capture the current tool's pane via `herdr agent read --lines <start_lines>`
   (default 80).
2. Ask an LLM to normalize it into strict JSON — one entry per question the
   agent is asking (`questions[]`, each with `options`/`multiple`/`suggested`).
   The model may answer `need_more`, which doubles the captured lines and
   re-asks (read-more loop, `max_read_more` cap); invalid JSON is retried once
   with the failure reason (`retries`).
3. Render a popup form with a fixed size (`question_form.height_ratio`,
   default 60% of the editor height; `question_form.width_ratio`, default 70%
   of the columns, clamped to 56–88 — identical across loading/form/fallback,
   no resize on morph).
   Each question is its own section separated by `---` rules (the buffer is
   `filetype=markdown` with `buftype=nofile`: syntax highlighting applies,
   markdown preview plugins don't attach). `space` toggles options (green `✓`
   when selected, no checkbox glyphs; radio when
   single-choice, checkbox when `multiple`; `suggested` items pre-selected and
   get the initial cursor), `tab`/`shift-tab` jump between selectable items,
   `a` opens the bottom input line to write a custom answer for the question
   under the cursor (prefilled with its previous content; `enter` promotes it
   to a real option of that question — appended after the originals and
   selected, later edits update it in place; `esc` keeps the draft),
   `ctrl+enter` submits, `esc` cancels. A question with nothing selected
   blocks the submit. Submission is the selected option texts verbatim —
   unlabeled for a single question,
   `Qk:` blocks separated by blank lines when there are several — sent back
   through the delivery **text channel** (a blocked agent refuses
   `herdr agent prompt`, so send-text + submit key is the only channel that
   reaches it).
4. Anything the LLM cannot parse — `no_question`, retries exhausted, missing
   API key — still opens the form in fallback mode: read-only raw capture plus
   the custom-answer line, so you can always answer without leaving nvim.

The LLM call is a small adapter (`llm.lua`, ADR-0002): built-in OpenAI-compatible
HTTP via curl, DeepSeek out of the box (`DEEPSEEK_API_KEY`), no LLM plugin
dependency; override the endpoint/model or plug a custom adapter via `llm.*`
options.

```lua
require("herder-agents").setup({
  llm = {
    base_url = "https://api.deepseek.com",
    api_key_env = "DEEPSEEK_API_KEY",
    model = "deepseek-chat",
    start_lines = 80,  -- first capture; doubled on need_more
    max_read_more = 2, -- read-more rounds
    retries = 1,       -- invalid-JSON retries (failure reason attached)
    extra_body = nil, -- extra fields deep-merged into the request body last (wins over
                      -- built-ins), e.g. { enable_thinking = false } to turn off thinking
    extra_headers = nil, -- extra HTTP headers, e.g. { ["X-Tenant"] = "team-a" }
    disable_thinking = false, -- inject the vendor's thinking-off field per base_url
                              -- (ollama/deepseek/dashscope/openrouter/openai); unknown
                              -- endpoints are left untouched — use extra_body instead
  },
})
```

**on_show hook.** `question_form.on_show` fires once when the form content is
on screen — both form and fallback modes count (loading doesn't, `space`
re-renders don't, but each new display does, e.g. form→form re-asks). It runs
after the initial cursor/focus is applied, so your adjustments land last;
errors in the callback are warned and never break the form. The same payload
is emitted afterwards as the `AIQuestionShown` User event:

```lua
require("herder-agents").setup({
  question_form = {
    -- ctx = { mode = "form"|"fallback", questions = {...},   -- normalized
    --         win = question winid, buf = question bufnr,    -- winids are
    --         input_win = input line winid,                  -- invalid after
    --         input_buf = input line bufnr }                 -- the popup closes
    -- extmarks you add in your own namespace survive the form's re-renders
    on_show = function(ctx)
      vim.wo[ctx.win].conceallevel = 0 -- show raw markdown instead of concealed
    end,
  },
})
```

**Dev command.** `:AIQuestionDev [file]` drives the same form from local
content instead of a live agent — for popup-rendering tests and extraction
prompt tuning. A `.json` file (or a json buffer, when called without an
argument) is treated as an LLM-response fixture: no network, it goes straight
through validation into the form (invalid fixtures fall back and show why).
Anything else (`.txt` capture snapshots, or the current buffer) runs the full
pipeline against the real LLM. Submitting in dev mode never delivers to the
agent: the composed text is printed to `:messages`, along with the raw LLM
response and stats (question count, read-more rounds, retries, elapsed ms).

## Prompt delivery

Prompts travel through a small delivery queue modeled after codex.nvim's
`pending_sends` design, preferring herdr's own agent integration (usage
borrowed from herdr-nvim):

- When the target pane is a herdr-registered agent, submission goes through
  `herdr agent prompt`: the server presses Enter for you, understands the
  agent state machine, and refuses when the agent is blocked. Waiting uses
  `herdr agent wait --until idle/working/unknown` (server-side, chunked
  timeouts) instead of client-side polling.
- Unregistered panes and custom tools fall back to the text channel:
  `pane send-text` with per-tool bracketed-paste encoding plus a submit key.
  codex `/queue` (tab submit) and append-only sends always use the text
  channel. Set `delivery.agent_channel = false` to force the text channel
  everywhere.
- A prompt is sent only once its pane is ready (agent status
  `idle`/`working`/`unknown`, or a foreground process for the text channel),
  re-checked after a short settle delay that skips the TUI initialization
  window — including prompts submitted while the agent already looks ready.
  Until then it is queued and delivered automatically once the agent is up.
  Startup screens no longer eat your text.
- Screen-detection agents like codex stay `unknown` after finishing a turn
  (herdr cannot distinguish their idle composer from a running one and never
  reports `idle`). `unknown` counts as ready: the prompt is submitted via
  `herdr agent prompt` after the settle re-check — herdr still refuses if the
  agent is actually blocked (approval dialog), keeping your draft for retry.
  Before this, waiting for `idle`/`working` timed out forever and codex
  prompts stayed permanently queued.
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
| `AIQuestionShown` | question form content is on screen (form and fallback; fires once per display — not while loading, not on option re-renders, again on form→form re-asks) | mode, questions, win, buf, input_win, input_buf |

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

### Completion

The prompt popup buffer uses filetype `aider-input`. If
[blink.cmp](https://github.com/Saghen/blink.cmp) is installed, the plugin
registers two sources for it by default — no user config needed:

- `herder_skills` — completes the **current tool's** skills (per-tool sources
  and triggers, see below), each item carrying description/documentation
- `herder_path` — file paths relative to the current working directory
  (reuses blink.cmp's built-in path source)

The skill list is acquired per current tool from `tools.<name>.skills`
(acquisition lives in `lua/herder-agents/skills.lua`). Built-in defaults:

| tool | mode | source | trigger | label |
| --- | --- | --- | --- | --- |
| opencode | api + fs fallback | `opencode api skill.list` (includes built-in/plugin skills); when it fails — the CLI intermittently truncates huge piped responses (exit code 0 but invalid JSON) — falls back to user `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills` + project `.opencode/skills`, `.claude/skills`, `.agents/skills` up to the git root | `@` | `id` |
| qodercli | fs | user `~/.agents/skills`, `~/.qoder/skills` + project `.qoder/skills` (cwd) | `/` | `id` |
| pi | fs | user `~/.pi/agent/skills`, `~/.agents/skills` + project `.pi/skills`, `.agents/skills` walked up to the git root | `/` | `skill:<id>` |

Two acquisition modes:

- **api** — `api = { argv }` runs the CLI and parses the JSON response
  (`{data: [...]}`; `{name, location}` entries are normalized too).
- **fs** — `user` / `project` (+ `project_up`) directory lists; a directory
  containing `SKILL.md` is one skill (frontmatter `name:`/`description:`
  override the directory name, `id` falls back to it). With `project_up`,
  project dirs are resolved from the cwd up to the git root.

`api` and the fs dirs can coexist: when the api call fails (exec error, non-zero
exit, or invalid JSON — e.g. the pipe-truncated large responses above), the fs
scan runs instead and a warning is shown once per session per tool. Large but
valid payloads parse fine. The api call itself transports stdout through a
unique temp file (upstream pipe truncation: Bun's async pipe writes lose the
buffer when the CLI `process.exit()`s early — anomalyco/opencode#52925, fix PR
#52955 pending; file redirects are synchronous and complete), with a 10s fetch
timeout that also degrades to the fs fallback. This transport layer can be
dropped once the upstream fix ships broadly.

Precedence is first-discovered-wins — user dirs first, then project roots from
the topmost ancestor down to the cwd (so user > ancestor > cwd, and duplicate
ids are never emitted). The list is cached per tool (and cwd) for
`completion.skill_ttl` seconds and refreshed in the background when the popup
opens; failures degrade silently to the previous/empty list. Tools without a
`skills` config get no skill completions. Custom tool example:

```lua
opts = {
  tools = {
    codex = {
      skills = { user = { "~/.codex/skills" }, project = { ".codex/skills" }, trigger = "$" },
    },
  },
}
```

Disable everything with `completion = { enabled = false }`.

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
