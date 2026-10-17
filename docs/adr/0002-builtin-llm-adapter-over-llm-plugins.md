# ADR-0002: LLM 提取走自带 adapter，不依赖 LLM 插件

- 状态:已接受
- 日期:2026-10-17

## 背景

question form（见 CONTEXT.md）需要把 agent 终端输出经 LLM 规范化为严格 JSON。候选：huggingface/llm.nvim、codecompanion/gp/gen/avante、simonw `llm` CLI、自带 Lua HTTP client。调研（2026-10）结论：llm.nvim 是纯 FIM ghost-text 补全（llm-ls 二进制），无任意 prompt 的 Lua API；codecompanion/gp/gen/avante 均无文档化的 headless 一次性 API，且重依赖、UI 耦合；`llm --schema`/`--tool` 能力完整但引入 Python 外部依赖（目标环境未装）。read-more 循环若走 tool_calls，则与 `response_format` 同请求互斥（OpenAI 系），且弱端点不支持 tools。

## 决定

1. **自带 adapter 接口 + 内置 OpenAI 兼容 HTTP 实现**（`llm.lua`，经 utils.exec* 通道包 curl，可注入测试），默认 DeepSeek（复用环境 `DEEPSEEK_API_KEY`），全字段可配。不依赖任何 LLM 插件。
2. **read-more 用判别式字段**（`status:"need_more"`），不用 tool_calls：任何支持 json_object 的兼容端点都可跑，循环留在 Lua 侧可测。
3. 提交答案走 delivery **text channel**：agent 提问等答案时处于 blocked，`herdr agent prompt` 会以 `agent_blocked` 拒收（CLI 实测，herdr 0.9.5）。

## 后果

- LLM 交互面（HTTP+重试+校验）由本仓库自维护；Anthropic 原生端点不支持 `response_format`，需 OpenAI 兼容门面（OpenRouter 等）才能接。
- 社区 adapter（codecompanion 等）仍可经 `config.llm.adapter` 后补，不破坏本决定。
