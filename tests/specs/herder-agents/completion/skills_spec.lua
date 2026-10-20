local plugin = require("herder-agents")

-- skill 补全（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("skill 补全", function()
  local utils = require("herder-agents.utils")
  local cfg = require("herder-agents.config")

  -- ---------------------------------------------------------------------------
  -- skill 补全获取层（skills.lua，配置驱动）：fs 模式（user/project 目录 +
  -- SKILL.md frontmatter，project_up 向上到 git 根）与 api 模式（CLI JSON 列表），
  -- 按工具 + cwd 分键缓存；completion/skills.lua 仅是 blink 适配层，按当前工具取数
  -- （包进局部函数：函数作用域独立计数，避免主 chunk 超出 200 局部上限）
  -- ---------------------------------------------------------------------------
  local function run_skill_tests()
    local skills = require("herder-agents.skills")

    -- fixture：用户级目录 / 假仓库（.git 平铺目录）/ 嵌套 cwd（sub/）/ 无 .git 的 plain/
    local base = "/tmp/opencode/herder-skills"
    local function write_skill(dir, fm_name, fm_desc)
      vim.fn.mkdir(dir, "p")
      local lines
      if fm_name then
        lines = { "---", "name: " .. fm_name, "description: " .. fm_desc, "---", "", "Body." }
      else
        lines = { "No frontmatter here." } -- 无 frontmatter：id 回落目录名
      end
      vim.fn.writefile(lines, dir .. "/SKILL.md")
    end
    local user_dir = base .. "/user-skills"
    write_skill(user_dir .. "/alpha", "alpha", "user alpha")
    write_skill(user_dir .. "/bare", nil)
    write_skill(user_dir .. "/dup", "dup", "user dup") -- 用户级 dup：应压过项目级
    local repo = base .. "/repo"
    vim.fn.mkdir(repo .. "/.git", "p") -- 假仓库（.git 平铺目录）
    write_skill(repo .. "/.agents/skills/dup", "dup", "ancestor dup")
    local sub = repo .. "/sub"
    write_skill(sub .. "/.pi/skills/deep", "deep", "deep pi")
    write_skill(sub .. "/.agents/skills/dup", "dup", "cwd dup")
    local plain = base .. "/plain" -- 无 .git：向上应走到文件系统根
    write_skill(plain .. "/.pi/skills/plain", nil)

    -- 真实脚本 fixture（端到端走 sh -c exec + 临时文件 + 读回 + 清理全链路）：
    -- 大载荷 ~600KB（贴近现场 65 技能 / 548KB），'b' 无尾换行保证 stdout 与
    -- JSON 逐字节一致
    local real_payload = base .. "/real-payload.json"
    vim.fn.writefile({
      vim.json.encode({
        data = { { id = "real", name = "Real Skill", description = string.rep("r", 600000), path = "/p/real" } },
      }),
    }, real_payload, "b")
    vim.fn.writefile({ "#!/bin/sh", 'exec cat "' .. real_payload .. '"', "" }, base .. "/fake-echo-cli.sh")
    vim.fn.setfperm(base .. "/fake-echo-cli.sh", "rwxr-xr-x")
    -- 失败脚本（非零退出）与慢脚本（超时 SIGKILL 用；脚本侧计数文件验证重复执行）
    vim.fn.writefile({ "#!/bin/sh", "exit 1", "" }, base .. "/fake-fail-cli.sh")
    vim.fn.setfperm(base .. "/fake-fail-cli.sh", "rwxr-xr-x")
    local slow_counter = base .. "/slow-counter"
    os.remove(slow_counter)
    vim.fn.writefile({
      "#!/bin/sh",
      'echo x >> "' .. slow_counter .. '"',
      "sleep 5",
      "printf '%s' '{\"data\":[]}'",
      "",
    }, base .. "/fake-slow-cli.sh")
    vim.fn.setfperm(base .. "/fake-slow-cli.sh", "rwxr-xr-x")

    -- 注册测试工具：myfs（带用户目录，user dup 胜出）/ myfs2（无用户目录，
    -- 祖先 dup 胜出）/ myapi1+myapi2（api 模式的两种响应形状）/
    -- myapi3（api+fs 共存：截断回退）/ myapi4（合法大响应）
    local saved_cwd = vim.fn.getcwd()
    local saved_tool = vim.g.ai_tool
    plugin.setup({
      tools = {
        myfs = {
          skills = {
            user = { user_dir },
            project = { ".pi/skills", ".agents/skills" },
            project_up = true,
            trigger = "/",
            label_prefix = "skill:",
          },
        },
        myfs2 = { skills = { project = { ".pi/skills", ".agents/skills" }, project_up = true, trigger = "/" } },
        myapi1 = { skills = { api = { "fake-skill-cli-1", "list" } } },
        myapi2 = { skills = { api = { "fake-skill-cli-2", "list" } } },
        myapi3 = {
          skills = {
            api = { "fake-skill-cli-3", "list" },
            user = { user_dir },
            project = { ".pi/skills" },
            project_up = true,
          },
        },
        myapi4 = { skills = { api = { "fake-skill-cli-4", "list" } } },
        myreal = { skills = { api = { base .. "/fake-echo-cli.sh" } } },
        myfail = { skills = { api = { base .. "/fake-fail-cli.sh" } } },
        myslow = { skills = { api = { base .. "/fake-slow-cli.sh" }, user = { user_dir } } },
      },
    })
    skills._reset()

    -- spec / trigger / triggers
    assert.truthy(
      skills.spec("myfs") ~= nil and skills.spec("crush") == nil,
      "skills.spec：配置返回表，未配置 nil"
    )
    assert.truthy(
      skills.trigger("myfs") == "/" and skills.trigger("crush") == "@",
      "trigger：默认 @，配置覆盖为 /"
    )
    assert.truthy(
      vim.tbl_contains(skills.spec("qodercli").user, "~/.agents/skills")
        and vim.tbl_contains(skills.spec("qodercli").user, "~/.qoder/skills"),
      "qodercli 默认 user 目录含 ~/.agents/skills 与 ~/.qoder/skills"
    )
    local trigs = skills.triggers()
    assert.truthy(
      vim.tbl_contains(trigs, "@") and vim.tbl_contains(trigs, "/"),
      "triggers：各工具触发字符的去重并集"
    )

    local function ids_of(entries)
      local out = {}
      for _, e in ipairs(entries or {}) do
        out[e.id] = true
      end
      return out
    end

    -- fs 模式：嵌套 cwd（repo/sub）向上到假仓库根，user > 祖先 > cwd（first-discovered-wins）
    vim.cmd("cd " .. sub)
    local fs_entries
    skills.list("myfs", function(entries)
      fs_entries = entries
    end)
    local myfs_ids = ids_of(fs_entries)
    assert.truthy(
      myfs_ids.alpha and myfs_ids.bare and myfs_ids.deep and myfs_ids.dup and #fs_entries == 4,
      "fs 列表：user 目录 + 上下两层 project 均发现，同 id 去重（dup 只留一份）"
    )
    for _, e in ipairs(fs_entries) do
      if e.id == "dup" then
        assert.truthy(
          e.description == "user dup",
          "fs 优先级：user 级 dup 压过祖先/cwd 级（first-discovered-wins）"
        )
      end
      if e.id == "bare" then
        assert.truthy(
          e.name == "bare" and e.path:find("/bare/SKILL.md$", 1, false) ~= nil,
          "fs 解析：无 frontmatter 时 id/name 回落目录名"
        )
      end
      if e.id == "alpha" then
        assert.truthy(e.description == "user alpha", "fs 解析：SKILL.md frontmatter 的 description 生效")
      end
    end
    assert.truthy(
      fs_entries[1].id == "alpha"
        and fs_entries[2].id == "bare"
        and fs_entries[3].id == "dup"
        and fs_entries[4].id == "deep",
      "fs 列表：扫描顺序确定（user 层排序在前，project 层按根序追加）"
    )

    -- myfs2（无 user 目录）：祖先层 dup 压过 cwd 层；嵌套 cwd 两层都发现
    local fs2_entries
    skills.list("myfs2", function(entries)
      fs2_entries = entries
    end)
    for _, e in ipairs(fs2_entries) do
      if e.id == "dup" then
        assert.truthy(e.description == "ancestor dup", "fs 优先级：无 user 时祖先层 dup 压过 cwd 层")
      end
    end
    local fs2_ids = ids_of(fs2_entries)
    assert.truthy(
      fs2_ids.deep and fs2_ids.dup,
      "upwalk 边界：嵌套 cwd 发现 cwd 层（sub/.pi/skills）与祖先层（repo/.agents/skills）"
    )

    -- 无 .git 的目录：向上走到文件系统根，cwd 层的 skill 仍被发现、不报错
    vim.cmd("cd " .. plain)
    local plain_entries
    skills.list("myfs2", function(entries)
      plain_entries = entries
    end)
    assert.truthy(
      ids_of(plain_entries).plain,
      "upwalk 边界：无 .git（走到文件系统根）仍发现 cwd 层 skill"
    )

    -- api 模式：两种响应形状归一化 + 缓存（新鲜期内第二次 list 不再 exec）
    vim.cmd("cd " .. saved_cwd)
    local api_calls = {}
    local cli3_calls = 0
    -- 截断响应 fixture：合法 JSON（含 70KB description）在 64KiB 处切断
    local truncated_json = vim.json
      .encode({
        data = { { id = "huge", name = "Huge", description = string.rep("x", 70000), path = "/p/huge" } },
      })
      :sub(1, 65536)
    -- 注入临时文件中转执行器（api_fetch 现走 exec_async_to_file）：假执行器契约
    -- 相同 {code, stdout, stderr}，忽略 timeout_ms；保存引用供真实链路测试后回装
    local skill_fake = function(argv, on_done)
      table.insert(api_calls, argv[1])
      if argv[1] == "fake-skill-cli-1" then
        on_done({
          code = 0,
          stdout = vim.json.encode({
            data = { { id = "alpha", name = "Alpha Skill", description = "api desc", path = "/p/alpha" } },
          }),
          stderr = "",
        })
      elseif argv[1] == "fake-skill-cli-2" then
        on_done({
          code = 0,
          stdout = vim.json.encode({ data = { { name = "beta", location = "/p/beta", description = "loc desc" } } }),
          stderr = "",
        })
      elseif argv[1] == "fake-skill-cli-3" then
        -- 复现现场 bug：CLI 经管道偶发截断大响应（退出码仍 0，JSON 被切在
        -- 字符串字面量中间 → 不完整），64KiB 边界与报告一致
        cli3_calls = cli3_calls + 1
        on_done({ code = 0, stdout = truncated_json, stderr = "" })
      elseif argv[1] == "fake-skill-cli-4" then
        -- 合法大响应（~600KB，贴近现场 65 技能 / 548KB）：大体积本身不是失败原因
        on_done({
          code = 0,
          stdout = vim.json.encode({
            data = { { id = "big", description = string.rep("y", 600000), path = "/p/big" } },
          }),
          stderr = "",
        })
      else
        on_done({ code = 0, stdout = "", stderr = "" })
      end
    end
    utils.set_exec_to_file(skill_fake)
    skills._reset()
    local api1
    skills.list("myapi1", function(entries)
      api1 = entries
    end)
    assert.truthy(
      api1
        and api1[1]
        and api1[1].id == "alpha"
        and api1[1].name == "Alpha Skill"
        and api1[1].description == "api desc"
        and api1[1].path == "/p/alpha",
      "api 模式：{id,...} 形状归一化"
    )
    local api2
    skills.list("myapi2", function(entries)
      api2 = entries
    end)
    assert.truthy(
      api2 and api2[1] and api2[1].id == "beta" and api2[1].name == "beta" and api2[1].path == "/p/beta",
      "api 模式：{name,location} 形状归一化（id/name、path/location 兼容）"
    )
    skills.list("myapi1", function() end)
    assert.truthy(#vim.tbl_filter(function(c)
      return c == "fake-skill-cli-1"
    end, api_calls) == 1, "缓存：新鲜期内第二次 list 不再执行 CLI")
    local none
    skills.list("crush", function(entries)
      none = entries
    end)
    assert.truthy(none ~= nil and #none == 0, "未配置 skills 的工具：list 回 {}（无 skill 补全）")

    -- api + fs 共存（myapi3）：截断响应（退出码 0、JSON 不完整）→ 自动回退目录
    -- 扫描 + 每会话每工具告警一次；回退结果进缓存，期内第二次 list 不再 exec/告警。
    -- myapi4：合法大响应（~600KB）照常从 api 解析（大体积 ≠ 失败）
    local saved_warn = utils.warn
    local warn_log = {}
    utils.warn = function(msg)
      table.insert(warn_log, tostring(msg))
    end
    vim.cmd("cd " .. sub)
    skills._reset()
    local api3
    skills.list("myapi3", function(entries)
      api3 = entries
    end)
    local api3_ids = ids_of(api3)
    assert.truthy(
      api3_ids.alpha and api3_ids.bare and api3_ids.dup and api3_ids.deep,
      "api 失败回退：截断响应（退出码 0）自动回落目录扫描（user + project 均生效）"
    )
    assert.truthy(
      #warn_log == 1
        and warn_log[1]:find("myapi3", 1, true) ~= nil
        and warn_log[1]:find("已回退目录扫描", 1, true) ~= nil,
      "api 失败告警：每工具只提示一次，说明截断原因与回退后果"
    )
    skills.list("myapi3", function() end)
    assert.truthy(
      #vim.tbl_filter(function(c)
        return c == "fake-skill-cli-3"
      end, api_calls) == 1 and #warn_log == 1,
      "api 失败回退：结果进缓存，期内第二次 list 不再 exec 也不再告警"
    )
    local api4
    skills.list("myapi4", function(entries)
      api4 = entries
    end)
    assert.truthy(
      api4 and api4[1] and api4[1].id == "big" and #api4[1].description == 600000 and api4[1].path == "/p/big",
      "api 大响应：合法的 ~600KB 输出照常解析（无 fs 字段）"
    )
    assert.truthy(#warn_log == 1, "api 大响应：成功不触发告警")

    -- ---------------------------------------------------------------------------
    -- 真实执行器路径（撤掉注入假执行器）：临时文件中转全链路 + 残留/超时断言。
    -- TMPDIR 指到 fixture tmpdir —— vim.fn.tempname 在调用时取 $TMPDIR（已实测），
    -- 残留 = tmpdir 下任何 *.json 文件（tempname 建的 nvim.<user>/XXXX 会话目录
    -- 与其内部的非 .json 文件是 vim 自身会话临时区，不属于本层残留）
    -- ---------------------------------------------------------------------------
    utils.set_exec_to_file(nil)
    local saved_tmpdir = vim.env.TMPDIR
    local tmpdir = base .. "/tmpdir"
    vim.fn.mkdir(tmpdir, "p")
    vim.fn.setenv("TMPDIR", tmpdir)
    assert.truthy(
      vim.fn.tempname():find(tmpdir, 1, true) == 1,
      "tempname 遵循调用时的 $TMPDIR（残留断言前提）"
    )
    local function json_residue(dir, out, depth)
      if depth > 6 then
        return
      end
      local ok, names = pcall(vim.fn.readdir, dir)
      if not ok or type(names) ~= "table" then
        return
      end
      for _, name in ipairs(names) do
        local p = dir .. "/" .. name
        if name:find(".json", 1, true) then -- 命中 "<x>.json" 与 "<x>.json.err" 两种中转文件
          table.insert(out, p)
        elseif vim.fn.isdirectory(p) == 1 then
          json_residue(p, out, depth + 1)
        end
      end
    end
    local residue = function()
      local out = {}
      json_residue(tmpdir, out, 0)
      return out
    end
    assert.truthy(#residue() == 0, "残留基线：tmpdir 初始无 *.json")

    -- 成功路径：真实脚本经 sh -c exec + 唯一临时文件读回 600KB JSON
    skills._reset()
    local real_entries
    skills.list("myreal", function(entries)
      real_entries = entries
    end)
    assert.truthy(
      vim.wait(5000, function()
        return real_entries ~= nil
      end, 10),
      "临时文件中转：真实 CLI 异步完成（事件循环等待回调）"
    )
    assert.truthy(
      real_entries and real_entries[1] and real_entries[1].id == "real" and #real_entries[1].description == 600000,
      "临时文件中转：600KB 响应完整读回并解析（文件重定向无管道截断）"
    )
    assert.truthy(#residue() == 0, "残留断言：成功路径零残留（临时文件已删除）")

    -- 失败路径：非零退出 → {}（无 fs 字段不回退），仍零残留
    local fail_entries
    skills.list("myfail", function(entries)
      fail_entries = entries
    end)
    vim.wait(5000, function()
      return fail_entries ~= nil
    end, 10)
    assert.truthy(
      fail_entries ~= nil and #fail_entries == 0,
      "失败脚本：非零退出回 {}（无 fs 字段不回退）"
    )
    assert.truthy(#residue() == 0, "残留断言：非零退出路径零残留")

    -- 超时路径：150ms SIGKILL（脚本 sleep 5）→ 回退 fs；in_flight 已清（第二次
    -- list 重新执行，脚本侧计数 +1）；全程不等满 5s
    skills._api_timeout_ms = 150
    skills._reset()
    local t0 = vim.uv.now()
    local slow1
    skills.list("myslow", function(entries)
      slow1 = entries
    end)
    vim.wait(10000, function()
      return slow1 ~= nil
    end, 5)
    local elapsed = vim.uv.now() - t0
    local slow1_ids = ids_of(slow1)
    assert.truthy(
      slow1_ids.alpha and slow1_ids.bare and slow1_ids.dup and #slow1 == 3,
      "超时回退：SIGKILL 后回落目录扫描（user 层 3 条）"
    )
    assert.truthy(
      elapsed < 3000,
      ("超时生效：~%dms 返回（SIGKILL 命中，未等满 5s sleep）"):format(elapsed)
    )
    assert.truthy(#residue() == 0, "残留断言：超时路径零残留")
    -- 回退结果已进缓存（与 myapi3 同款行为）：立即二次 list 走缓存同步回调，
    -- 不重复执行 CLI（脚本计数不变），也证明回调投递无死锁
    local slow2
    skills.list("myslow", function(entries)
      slow2 = entries
    end)
    local ok_cnt, cnt = pcall(vim.fn.readfile, slow_counter)
    assert.truthy(
      slow2 ~= nil and #slow2 == 3 and ok_cnt and #cnt == 1,
      "超时路径：二次 list 走缓存的回退结果（同步回调，不重复 exec）"
    )
    -- reset 后再 list：超时拉取后链路完全可复用，重新执行 CLI（脚本计数 +1）
    skills._reset()
    local slow3
    skills.list("myslow", function(entries)
      slow3 = entries
    end)
    vim.wait(10000, function()
      return slow3 ~= nil
    end, 5)
    ok_cnt, cnt = pcall(vim.fn.readfile, slow_counter)
    assert.truthy(
      slow3 ~= nil and #slow3 == 3 and ok_cnt and #cnt >= 2,
      "超时路径：in_flight 已清，reset 后再 list 重新执行 CLI（脚本计数 ≥2）"
    )
    assert.truthy(#residue() == 0, "残留断言：超时 + 重复拉取零残留")

    -- 还原 TMPDIR / 超时 / 假执行器（适配层测试还要用）/ 告警
    if saved_tmpdir then
      vim.env.TMPDIR = saved_tmpdir
    else
      vim.env.TMPDIR = nil
    end
    skills._api_timeout_ms = 10000
    utils.set_exec_to_file(skill_fake)
    utils.warn = saved_warn

    -- blink 适配层（completion/skills.lua）：按当前工具取数、label 前缀、触发字符判定
    local adapter = require("herder-agents.completion.skills")
    local source = adapter.new({})
    assert.truthy(
      vim.tbl_contains(source:get_trigger_characters(), "/") and vim.tbl_contains(source:get_trigger_characters(), "@"),
      "适配层：get_trigger_characters 返回触发字符并集"
    )
    skills._reset()
    vim.g.ai_tool = "myfs"
    vim.cmd("cd " .. sub)
    local slash_items
    source:get_completions({ line = "/al", keyword = "al", cursor = { 0, 3 } }, function(res)
      slash_items = res.items
    end)
    local slash_labels = {}
    for _, it in ipairs(slash_items or {}) do
      table.insert(slash_labels, it.label)
    end
    assert.truthy(
      vim.tbl_contains(slash_labels, "skill:alpha") and vim.tbl_contains(slash_labels, "skill:deep"),
      "适配层：/ 触发（myfs）label 带 label_prefix（skill:<id>）"
    )
    for _, it in ipairs(slash_items or {}) do
      if it.label == "skill:alpha" then
        assert.truthy(it.detail == "skill: user alpha", "适配层：detail = skill: <description>")
      end
    end
    -- 触发字符不匹配（myfs 是 "/"，输入的是 "@"）→ 空
    local mismatch
    source:get_completions({ line = "@al", keyword = "al", cursor = { 0, 3 } }, function(res)
      mismatch = res.items
    end)
    assert.truthy(mismatch ~= nil and #mismatch == 0, "适配层：触发字符与当前工具配置不符时回空")
    -- "@" 触发（myapi1，无 label_prefix）
    vim.g.ai_tool = "myapi1"
    local at_items
    source:get_completions({ line = "@al", keyword = "al", cursor = { 0, 3 } }, function(res)
      at_items = res.items
    end)
    assert.truthy(
      at_items ~= nil and #at_items == 1 and at_items[1].label == "alpha",
      "适配层：@ 触发 label 即 id（无前缀）"
    )

    -- 还原：执行器注入、超时、cwd、当前工具、测试工具与 skill 缓存
    utils.set_exec(nil)
    utils.set_exec_to_file(nil)
    utils.set_exec_async(nil)
    skills._reset()
    skills._api_timeout_ms = 10000
    vim.cmd("cd " .. saved_cwd)
    vim.g.ai_tool = saved_tool
    for _, name in ipairs({ "myfs", "myfs2", "myapi1", "myapi2", "myapi3", "myapi4", "myreal", "myfail", "myslow" }) do
      cfg.options.tools[name] = nil
    end
    cfg.options.tool_order = vim.tbl_filter(function(n)
      return cfg.options.tools[n] ~= nil
    end, cfg.options.tool_order)
  end
  it("skill 补全", function()
    run_skill_tests()
  end)
end)
