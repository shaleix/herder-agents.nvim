实现完成。@wayfinder 的 destination 已在一个 session 内走完，不需要建 map。
用法
:AIVisibleFiles
可选快捷键（默认不绑，沿用插件惯例）：
require("herder-agents").setup({
  keys = { visible_files = "<leader>hv" },
})
行为
- 抓取当前工具对应 agent pane 的 visible 视口：herdr pane read <pane_id> --source visible --format text（不翻 scrollback）。
- 按 termscope 的算法提取：剥 ANSI / ┃│ 边框 → 清行首列表符与引号 → token / 引号 span / 整行 → 对 pane cwd、git 仓库根、home 解析 → 只保留磁盘上真实存在的常规文件 → 保留 file:line[:col] → 按出现顺序去重。
- 仓库索引：fd/fdfind（--type f --type d --hidden --follow --exclude .git，5s 超时、5000 条上限），缺失或失败回退 git ls-files；根目录是 $HOME 时跳过。
- 有候选：走 fzf-lua 的 files provider（候选写入临时文件，cmd = cat <tmp>，on_close 清理），预览、图标、enter 当前窗口 :edit + line:col 跳转都复用 provider 自带行为。
- 无可见候选：回退 fzf-lua 正常仓库文件列表，标题标明 fallback。
- fzf-lua 不可用或调用失败：回退 utils.pick（fzf-lua 优先，否则 vim.ui.select），选中后用 open_target 解析并跳转。
- utils.exec 新增可选 { cwd, timeout }，旧调用与测试 stub 不受影响。
文件
- 新增 lua/herder-agents/visible_files.lua — 捕获/搜索根/仓库索引/提取/解析/打开（纯数据层）。
- 新增 lua/herder-agents/ui/visible_files.lua — fzf-lua 编排与回退。
- init.lua — :AIVisibleFiles、keys.visible_files、公开 M.visible_files()。
- config.lua — 命令/快捷键配置项。
- README / CONTEXT.md — 文档与 visible files 术语。
- test/smoke.lua — 100 项新用例。
验证
- nvim --headless -u NONE --cmd "set rtp^=$PWD" -l test/smoke.lua → ALL PASSED。
- 真机 headless 数据层验证（repo 39 个文件）：
lua/herder-agents/utils.lua:137:9
README.md
test/smoke.lua
lua/herder-agents/visible_files.lua
parse_target / resolve_existing_path 均正确解析并落到绝对路径。
- git diff --check 干净；新文件通过 stylua --check。
