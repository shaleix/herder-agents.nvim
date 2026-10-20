-- visible files（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("visible files", function()
  local utils = require("herder-agents.utils")
  local delivery = require("herder-agents.delivery")

  -- ---------------------------------------------------------------------------
  -- visible files（visible_files.lua 数据层 + ui/visible_files.lua 编排）：
  -- 当前 agent pane 可见视口 → 真实文件候选（termscope 移植，保留 file:line:col）
  -- → fzf-lua files provider 挑选。fixture：假仓库 + 假执行器
  -- （herdr pane read / git rev-parse / fd），fzf-lua 经 package.preload stub
  -- （包进局部函数：函数作用域独立计数，避免主 chunk 200 局部上限）
  -- ---------------------------------------------------------------------------
  local function run_visible_files_tests()
    local vf = require("herder-agents.visible_files")
    local ui_vf = require("herder-agents.ui.visible_files")

    -- fixture 假仓库（src/main.py 写满 50 行：open_target 光标 42 行断言用）
    local base = "/tmp/opencode/herder-visible-files"
    vim.fn.delete(base, "rf")
    local root = base .. "/repo"
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.mkdir(root .. "/docs", "p")
    vim.fn.mkdir(root .. "/pkg", "p")
    vim.fn.mkdir(root .. "/test", "p")
    vim.fn.mkdir(root .. "/with space", "p")
    vim.fn.writefile({ "readme" }, root .. "/README.md")
    local main_lines = {}
    for i = 1, 50 do
      main_lines[i] = "line " .. i
    end
    vim.fn.writefile(main_lines, root .. "/src/main.py")
    vim.fn.writefile({ "# guide" }, root .. "/docs/guide.md")
    vim.fn.writefile({ "x = 1" }, root .. "/pkg/a.py")
    vim.fn.writefile({ "m" }, root .. "/test/mentioned.md")
    vim.fn.writefile({ "notes" }, root .. "/with space/notes.md")
    -- fd 扫描形状：root 相对路径（文件 + 目录混排）
    local repo_paths = {
      "README.md",
      "docs",
      "docs/guide.md",
      "pkg",
      "pkg/a.py",
      "src",
      "src/main.py",
      "test",
      "test/mentioned.md",
      "with space",
      "with space/notes.md",
    }

    -- clean_visible_line：列表前缀 / 引号 / 尾标点 / pane 边框装饰
    assert.truthy(
      vf.clean_visible_line("- src/main.py:42:3") == "src/main.py:42:3",
      "clean_visible_line：- 前缀剥除"
    )
    assert.truthy(
      vf.clean_visible_line("* docs/guide.md,") == "docs/guide.md",
      "clean_visible_line：* 前缀 + 尾逗号"
    )
    assert.truthy(vf.clean_visible_line("1) README") == "README", "clean_visible_line：1) 编号前缀")
    assert.truthy(vf.clean_visible_line("12. a.lua") == "a.lua", "clean_visible_line：12. 编号前缀")
    assert.truthy(vf.clean_visible_line("• pkg/a.py:7") == "pkg/a.py:7", "clean_visible_line：• 圆点前缀")
    assert.truthy(
      vf.clean_visible_line("`docs/guide.md`") == "docs/guide.md",
      "clean_visible_line：反引号包裹剥除"
    )
    assert.truthy(vf.clean_visible_line("pkg/a.py:7.") == "pkg/a.py:7", "clean_visible_line：尾部句点剥除")
    assert.truthy(
      vf.clean_visible_line('"notes.md";') == 'notes.md"',
      "clean_visible_line：引号按端剥除（尾分号先被剥，尾引号保留，termscope 行为）"
    )
    assert.truthy(
      vf.clean_visible_line("┃ - src/main.py:42:3 ┃") == "src/main.py:42:3",
      "clean_visible_line：┃ pane 边框剥除"
    )
    assert.truthy(vf.clean_visible_line("│ README │") == "README", "clean_visible_line：│ 边框剥除")

    -- strip_ansi：OSC（BEL / ST 终止）与 CSI
    assert.truthy(vf.strip_ansi("\27]0;title\7abc") == "abc", "strip_ansi：OSC BEL 终止")
    assert.truthy(vf.strip_ansi("\27]8;;http://x\27\\ok") == "ok", "strip_ansi：OSC ST 终止")
    assert.truthy(vf.strip_ansi("\27[1mbold\27[0m plain") == "bold plain", "strip_ansi：CSI SGR")

    -- 假执行器：herdr pane read / git rev-parse / fd / git ls-files 分流应答
    local vf_log = {}
    local pane_screen = { code = 0, stdout = "" }
    local fd_lines = repo_paths
    utils.set_exec(function(argv, opts)
      table.insert(vf_log, { argv = argv, opts = opts })
      if argv[1] == "herdr" and argv[2] == "pane" and argv[3] == "read" then
        return { code = pane_screen.code, stdout = pane_screen.stdout }
      end
      if argv[1] == "git" and argv[4] == "rev-parse" then
        return { code = 0, stdout = root .. "\n" }
      end
      if argv[1] == "fd" or argv[1] == "fdfind" then
        return { code = 0, stdout = table.concat(fd_lines, "\n") .. "\n" }
      end
      if argv[1] == "git" and argv[4] == "ls-files" then
        return { code = 0, stdout = table.concat(fd_lines, "\n") .. "\n" }
      end
      return { code = 0, stdout = "" }
    end)

    -- capture：argv 形状 + stdout 原样 + 非零退出回 nil
    pane_screen = { code = 0, stdout = "screen text" }
    assert.truthy(vf.capture("p1") == "screen text", "capture：pane read 的 stdout 原样返回")
    local cap = vf_log[#vf_log]
    assert.truthy(
      cap.argv[1] == "herdr"
        and cap.argv[2] == "pane"
        and cap.argv[3] == "read"
        and cap.argv[4] == "p1"
        and vim.tbl_contains(cap.argv, "--source")
        and vim.tbl_contains(cap.argv, "visible")
        and vim.tbl_contains(cap.argv, "--format")
        and vim.tbl_contains(cap.argv, "text"),
      "capture argv：herdr pane read <id> --source visible --format text"
    )
    pane_screen = { code = 1, stdout = "" }
    assert.truthy(vf.capture("p1") == nil, "capture：非零退出回 nil")

    -- search_root：git rev-parse 取仓库根（argv 含 -C <cwd> 与 --show-toplevel）
    assert.truthy(vf.search_root(root .. "/src") == root, "search_root：git rev-parse 命中仓库根")
    local sr = vf_log[#vf_log]
    assert.truthy(
      sr.argv[1] == "git"
        and sr.argv[2] == "-C"
        and sr.argv[3] == root .. "/src"
        and vim.tbl_contains(sr.argv, "rev-parse")
        and vim.tbl_contains(sr.argv, "--show-toplevel"),
      "search_root argv：git -C <cwd> rev-parse --show-toplevel"
    )

    -- repo_files：fd 输出按序返回 + argv/cwd 断言 + $HOME 守卫 + 5000 行 cap
    local n_log = #vf_log
    assert.truthy(
      vim.deep_equal(vf.repo_files(root), repo_paths),
      "repo_files：fd 行按序返回（root 相对路径）"
    )
    assert.truthy(vf.last_repo_source == "fd" or vf.last_repo_source == "fdfind", "repo_files：记录 fd 数据源")
    local rf = vf_log[#vf_log]
    assert.truthy(
      (rf.argv[1] == "fd" or rf.argv[1] == "fdfind")
        and vim.tbl_contains(rf.argv, "--type")
        and vim.tbl_contains(rf.argv, "f")
        and vim.tbl_contains(rf.argv, "d")
        and vim.tbl_contains(rf.argv, "--hidden")
        and vim.tbl_contains(rf.argv, "--follow")
        and vim.tbl_contains(rf.argv, "--exclude")
        and vim.tbl_contains(rf.argv, ".git")
        and rf.argv[#rf.argv] == ".",
      "repo_files argv：fd --type f --type d --hidden --follow --exclude .git ."
    )
    assert.truthy(rf.opts ~= nil and rf.opts.cwd == root, "repo_files：fd 以仓库根为 cwd（opts 透传 exec）")
    n_log = #vf_log
    assert.truthy(
      #vf.repo_files(vim.fn.expand("~")) == 0,
      "repo_files：root=$HOME 时回空（不索引，termscope 同款守卫）"
    )
    assert.truthy(vf.last_repo_source == "skipped ($HOME)", "repo_files：$HOME 守卫记录 skipped")
    assert.truthy(#vf_log == n_log, "repo_files：$HOME 守卫不发起任何 CLI")
    local many = {}
    for i = 1, 5100 do
      many[i] = "f" .. i .. ".txt"
    end
    fd_lines = many
    assert.truthy(#vf.repo_files(root) == 5000, "repo_files：输出截断到 5000 行上限")
    fd_lines = repo_paths

    -- extract_visible_candidates：行号列号 / 引号 / 独立 README / 唯一 basename /
    -- 空格路径 / 不存在过滤 / 外观序 + 去重
    local screen = table.concat({
      "Working on src/main.py:42:3 now",
      "Read `docs/guide.md` for details.",
      "README",
      "Edited pkg/a.py:7 -- wait",
      "Missing ghost/nope.lua should vanish",
      'Read "with space/notes.md" for context.',
      "See @test/mentioned.md:9 for the mention.",
      "README again (dedupe)",
    }, "\n")
    local expected =
      { "src/main.py:42:3", "docs/guide.md", "README.md", "pkg/a.py:7", "with space/notes.md", "test/mentioned.md:9" }
    assert.truthy(
      vim.deep_equal(vf.extract_visible_candidates(screen, repo_paths, root, root), expected),
      "extract_visible_candidates：p:l:c / 引号 / 独立 README→.md / 唯一 basename / 空格路径 / @提及 / 过滤 / 保序去重"
    )
    -- 用户消息里的附件提及（插件 Relate file 格式）：@path 必须能解析
    local at_screen = table.concat({
      "  ┃  herdr panne 中的内容如 文件内容",
      "  ┃  使用AIVisibleFiles 未匹配到任何一条, 定位一下问题",
      "  ┃  Relate file:",
      "  ┃  - @test/mentioned.md",
    }, "\n")
    assert.truthy(
      vim.deep_equal(vf.extract_visible_candidates(at_screen, repo_paths, root, root), { "test/mentioned.md" }),
      "extract_visible_candidates：@path 附件提及可解析"
    )
    -- 诊断日志：逐 token 解析轨迹 + @ 剥离 + HIT/miss
    local dbg_logs = {}
    vf.extract_visible_candidates("@test/mentioned.md:9", repo_paths, root, root, {
      log = function(msg)
        dbg_logs[#dbg_logs + 1] = msg
      end,
    })
    local dbg_joined = table.concat(dbg_logs, "\n")
    assert.truthy(
      dbg_joined:find("@ stripped", 1, true) ~= nil
        and dbg_joined:find("try ", 1, true) ~= nil
        and dbg_joined:find("HIT test/mentioned.md:9", 1, true) ~= nil,
      "extract debug log：@ 剥离 / 路径尝试 / HIT 轨迹"
    )
    assert.truthy(vf.VERSION == "visible-files/3", "visible_files.VERSION 可用于确认运行版本")
    -- 终端硬换行：上一行接近正文宽度时与下一行拼接（src/ma + in.py:42）
    local wrap_screen = table.concat({
      string.rep("x", 60) .. " src/ma",
      "in.py:42 tail",
      string.rep("y", 10),
    }, "\n")
    assert.truthy(
      vim.deep_equal(vf.extract_visible_candidates(wrap_screen, repo_paths, root, root), { "src/main.py:42" }),
      "extract_visible_candidates：终端硬换行拼接（src/ma + in.py:42）"
    )

    -- parse_target：p:l:c（col 保留）/ p:l（引号+尾标点）/ p-l- / 纯路径
    local t = vf.parse_target("src/main.py:42:3")
    assert.truthy(
      t.path == "src/main.py" and t.line == 42 and t.col == 3,
      "parse_target：p:l:c 保留 col（Python 版丢弃）"
    )
    t = vf.parse_target("`docs/guide.md:7`")
    assert.truthy(t.path == "docs/guide.md" and t.line == 7 and t.col == nil, "parse_target：p:l（引号剥离）")
    t = vf.parse_target('"docs/guide.md:7."')
    assert.truthy(t.path == "docs/guide.md" and t.line == 7, "parse_target：双引号 + 尾点剥离")
    t = vf.parse_target("pkg/a.py-7-")
    assert.truthy(t.path == "pkg/a.py" and t.line == 7, "parse_target：p-l- 上下文格式")
    t = vf.parse_target("plain.lua.")
    assert.truthy(t.path == "plain.lua" and t.line == nil, "parse_target：纯路径剥尾点")
    t = vf.parse_target("@src/main.py:42:3")
    assert.truthy(
      t.path == "src/main.py" and t.line == 42 and t.col == 3,
      "parse_target：@提及前缀剥离（附件语法）"
    )

    -- resolve_existing_path：root 相对 / 绝对 / ~ 展开（HOME 注入）/ 目录不解析
    assert.truthy(
      vf.resolve_existing_path("src/main.py", root, root) == root .. "/src/main.py",
      "resolve_existing_path：root 相对命中常规文件"
    )
    assert.truthy(
      vf.resolve_existing_path(root .. "/README.md", root, root) == root .. "/README.md",
      "resolve_existing_path：绝对路径命中"
    )
    assert.truthy(
      vf.resolve_existing_path("src", root, root) == nil,
      "resolve_existing_path：目录不是候选（仅常规文件）"
    )
    assert.truthy(
      vf.resolve_existing_path("ghost/nope.lua", root, root) == nil,
      "resolve_existing_path：不存在回 nil"
    )
    local saved_home = vim.env.HOME
    vim.env.HOME = base
    vim.fn.writefile({ "home" }, base .. "/home-file.txt")
    assert.truthy(
      vf.resolve_existing_path("~/home-file.txt", root, root) == base .. "/home-file.txt",
      "resolve_existing_path：~/ 展开（HOME 注入）"
    )
    vim.env.HOME = saved_home

    -- open_target：edit + 光标 line:col；失败 warn 不打开
    vim.cmd("enew!")
    vf.open_target("src/main.py:42:3", root, root)
    assert.truthy(vim.fn.expand("%:p") == root .. "/src/main.py", "open_target：edit 打开解析后的绝对路径")
    assert.truthy(
      vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 42, 2 }),
      "open_target：光标落到 42:3（{42,2}）"
    )
    local saved_warn = utils.warn
    local warns = {}
    utils.warn = function(msg)
      table.insert(warns, tostring(msg))
    end
    vf.open_target("ghost/nope.lua:1", root, root)
    utils.warn = saved_warn
    assert.truthy(#warns == 1, "open_target：解析失败 warn 并返回（不打开）")
    vim.cmd("enew!")

    -- UI 编排：panes / fzf-lua stub（headless 无 herdr、无 fzf）
    local saved_panes_mod = package.loaded["herder-agents.panes"]
    local saved_preload_fzf = package.preload["fzf-lua"]
    local saved_loaded_fzf = package.loaded["fzf-lua"]
    local saved_tool = vim.g.ai_tool

    package.loaded["herder-agents.panes"] = {
      lookup = function()
        return { pane_id = "p1", cwd = root, foreground_cwd = root }
      end,
    }
    local captured_fzf, captured_exec
    package.preload["fzf-lua"] = function()
      return {
        files = function(opts)
          captured_fzf = opts
        end,
        fzf_exec = function(entries, opts)
          captured_exec = { entries = entries, opts = opts }
        end,
      }
    end
    package.loaded["fzf-lua"] = nil
    vim.g.ai_tool = "vf-tool"
    utils.set_fzf_available(function()
      return true
    end)

    -- ≥1 可见候选：fzf_exec 直接携带候选（不再走 files provider + cat 链路）
    pane_screen = { code = 0, stdout = screen }
    captured_fzf, captured_exec = nil, nil
    ui_vf.open()
    assert.truthy(
      captured_exec ~= nil and vim.deep_equal(captured_exec.entries, expected),
      "UI：fzf_exec 直接携带可见候选（Lua 侧写管道，必然送达）"
    )
    assert.truthy(
      captured_exec.opts ~= nil and captured_exec.opts.prompt:find("Visible files>", 1, true) ~= nil,
      "UI：prompt = Visible files>"
    )
    assert.truthy(captured_fzf == nil, "UI：可见候选不调用 files provider（自定义 cmd 链路已弃用）")

    -- 0 可见候选：回退 repo files provider（无 cmd、fallback prompt/title）
    pane_screen = { code = 0, stdout = "just chatting, no paths at all here" }
    captured_fzf, captured_exec = nil, nil
    ui_vf.open()
    assert.truthy(
      captured_exec == nil and captured_fzf ~= nil and captured_fzf.cmd == nil,
      "UI：无候选时回退 files provider"
    )
    assert.truthy(
      captured_fzf.prompt:find("No visible files", 1, true) ~= nil
        and captured_fzf.winopts.title == " Repo files (fallback) ",
      "UI：回退 prompt / title（No visible files — repo files）"
    )

    -- fzf binary 缺失（模块在但 fzf 不在 PATH）：不调用任何 fzf 入口，回退 vim.ui.select
    utils.set_fzf_available(function()
      return false
    end)
    local saved_select = vim.ui.select
    local selected_items = nil
    vim.ui.select = function(items)
      selected_items = items
    end
    captured_fzf, captured_exec = nil, nil
    pane_screen = { code = 0, stdout = screen }
    ui_vf.open()
    vim.ui.select = saved_select
    assert.truthy(captured_fzf == nil and captured_exec == nil, "UI：fzf binary 缺失时不调用 fzf 入口")
    assert.truthy(
      selected_items ~= nil and vim.deep_equal(selected_items, expected),
      "UI：fzf binary 缺失时回退 vim.ui.select（候选列表）"
    )

    -- :AIVisibleFiles!：debug 诊断日志（版本/捕获/仓库/逐 token/picker 分支）
    utils.set_fzf_available(function()
      return true
    end)
    local saved_echo = vim.api.nvim_echo
    local saved_info = utils.info
    local infos = {}
    vim.api.nvim_echo = function() end
    utils.info = function(msg)
      infos[#infos + 1] = tostring(msg)
    end
    captured_fzf, captured_exec = nil, nil
    pane_screen = { code = 0, stdout = screen }
    ui_vf.open({ debug = true })
    vim.api.nvim_echo = saved_echo
    utils.info = saved_info
    local log_path = infos[#infos] and infos[#infos]:match("→ (.+)$")
    local full_log = log_path and vim.fn.readfile(log_path) or {}
    local dbg = table.concat(full_log, "\n")
    assert.truthy(dbg:find("visible_files visible-files/3", 1, true) ~= nil, "UI debug：输出版本/环境日志")
    assert.truthy(dbg:find("candidates:", 1, true) ~= nil, "UI debug：输出候选数")
    assert.truthy(dbg:find("@ stripped", 1, true) ~= nil, "UI debug：输出 @ 提及剥离轨迹")
    assert.truthy(dbg:find("picker: fzf_exec", 1, true) ~= nil, "UI debug：输出 picker 分支")
    assert.truthy(
      #infos >= 1 and infos[#infos]:find("diagnostics", 1, true) ~= nil,
      "UI debug：日志文件路径提示"
    )
    if log_path then
      os.remove(log_path)
    end
    local cap_path = dbg:match("capture file: ([^\n]+)")
    if cap_path then
      os.remove(cap_path)
    end

    -- 还原 stub 与全局态
    utils.set_fzf_available(nil)
    package.loaded["herder-agents.panes"] = saved_panes_mod
    package.preload["fzf-lua"] = saved_preload_fzf
    package.loaded["fzf-lua"] = saved_loaded_fzf
    vim.g.ai_tool = saved_tool
    utils.set_exec(nil)
    vim.fn.delete(base, "rf")
  end
  it("visible files", function()
    run_visible_files_tests()
  end)
end)
