local plugin = require("herder-agents")

-- 独立实例基线：原单文件套件由 plugin 段先 setup（命令注册、默认不绑键）；
-- plenary 每个 spec 一个新 nvim 实例，这里自建同样基线。
vim.g.mapleader = " "
require("herder-agents").setup({ tools = { mycli = { title = " My CLI Chat " } } })
local has_map = require("tests.util.util").has_map

-- 宽度 toggle（:HerdrShrinkToggle）（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("宽度 toggle（:HerdrShrinkToggle）", function()
  it("宽度 toggle（:HerdrShrinkToggle）", function()
    local utils = require("herder-agents.utils")
    local panes = require("herder-agents.panes")
    local saved_env = vim.env.HERDR_ENV -- 原单文件沿用上一段保存的值；上一段尾部已还原

    -- ---------------------------------------------------------------------------
    -- 宽度 toggle（:HerdrShrinkToggle）：调整 nvim 在其归属 split 内容宽中的
    -- 占比（标准布局即全 tab 宽），在两个固定锚点间切换：toggle_ratio（默认
    -- 0.32）↔ 默认分屏比例 split.ratio（默认 0.55）。amount 语义（活体标定）=
    -- 被推边界所属 split 的 ratio 增量 —— fixture 必须带 splits 字段。与 tab 内
    -- pane 数量无关（agent 再 split 出新 pane 也照常工作）：收窄 = 邻侧 pane 吃进
    -- （推 nvim|邻侧 分界），恢复 = 直接扩张 nvim。无状态（曾按按压时比例记基准，
    -- 窄态/连按会污染成窄值死循环）；zoomed / 上下布局 / 独占 tab / 邻距异常时
    -- 守卫拦截
    -- ---------------------------------------------------------------------------
    vim.env.HERDR_ENV = "1"
    local function mk_layout_fake(pane_tbl, layout_tbl, cur_tab, cur_pane_id, resize_result)
      local argv_log = {}
      local exec = function(argv)
        table.insert(argv_log, argv)
        if argv[2] == "pane" and argv[3] == "current" then
          return {
            code = 0,
            stdout = vim.json.encode({ result = { pane = { tab_id = cur_tab, pane_id = cur_pane_id } } }),
          }
        end
        if argv[2] == "pane" and argv[3] == "list" then
          return { code = 0, stdout = vim.json.encode({ result = { panes = pane_tbl } }) }
        end
        if argv[2] == "pane" and argv[3] == "layout" then
          return { code = 0, stdout = vim.json.encode({ result = { layout = layout_tbl } }) }
        end
        if argv[2] == "pane" and argv[3] == "resize" then
          return { code = 0, stdout = vim.json.encode({ result = { resize = resize_result or { changed = true } } }) }
        end
        return { code = 0, stdout = "" }
      end
      local clear = function()
        for i = #argv_log, 1, -1 do
          argv_log[i] = nil
        end
      end
      return exec, argv_log, clear
    end
    local function resize_calls(argv_log)
      local calls = {}
      for _, argv in ipairs(argv_log) do
        if argv[2] == "pane" and argv[3] == "resize" then
          local opts = {}
          for i = 4, #argv, 2 do
            opts[argv[i]] = argv[i + 1]
          end
          table.insert(calls, opts)
        end
      end
      return calls
    end

    -- 布局：nvim 左 130 cols + agent 右 70 cols（agent 在右，当前占比 0.65）
    -- toggle_ratio 默认 0.32：收窄后布局为 nvim 64 / agent 136（64/200 = 0.32）
    -- 语义：nvim 占其归属 split 内容宽的比例（标准 root split 布局下即全 tab 宽）
    local st_panes = { { label = "opencode", tab_id = "t2", pane_id = "p-agent", cwd = vim.fn.getcwd() } }
    local function layout_of(nvim_w, agent_w)
      return {
        zoomed = false,
        panes = {
          { pane_id = "p-nvim", rect = { x = 0, y = 0, width = nvim_w, height = 60 } },
          { pane_id = "p-agent", rect = { x = nvim_w, y = 0, width = agent_w, height = 60 } },
        },
        splits = {
          {
            id = "split_0_root",
            direction = "right",
            ratio = nvim_w / (nvim_w + agent_w),
            rect = { x = 0, y = 0, width = nvim_w + agent_w, height = 60 },
          },
        },
      }
    end

    -- 首按：收窄 0.65 → 0.32（邻 pane 在右 → agent 向左吃进，amount = 0.33）
    local st_exec, st_log, st_clear = mk_layout_fake(st_panes, layout_of(130, 70), "t2", "p-nvim")
    utils.set_exec(st_exec)
    panes.shrink_toggle("opencode")
    local st_calls = resize_calls(st_log)
    assert.truthy(
      #st_calls == 1
        and st_calls[1]["--pane"] == "p-agent"
        and st_calls[1]["--direction"] == "left"
        and st_calls[1]["--amount"] == "0.3300",
      "宽度 toggle：首按收窄（邻 pane 吃进，方向/比例差正确）"
    )
    assert.truthy(vim.g.herd_shrink_state == nil, "宽度 toggle：固定锚点切换，不写 vim.g 基准")

    -- 再按：0.32 → 默认分屏比例 0.55：直接向右扩张 nvim 自身（amount = 0.55-0.32）
    local st2_exec, st2_log = mk_layout_fake(st_panes, layout_of(64, 136), "t2", "p-nvim")
    utils.set_exec(st2_exec)
    panes.shrink_toggle("opencode")
    st_calls = resize_calls(st2_log)
    assert.truthy(
      #st_calls == 1
        and st_calls[1]["--pane"] == "p-nvim"
        and st_calls[1]["--direction"] == "right"
        and st_calls[1]["--amount"] == "0.2300",
      "宽度 toggle：再按恢复默认分屏比例 0.55（直接扩张 nvim）"
    )

    -- agent 在左侧的镜像：nvim x=70 w=130，agent x=0 w=70 → 收窄 = agent 向右吃进
    -- nvim 是 root split 的右孩子：ratio 0.35（边界 x=70），nvim 占比 = 1−0.35
    local mirror_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 70, y = 0, width = 130, height = 60 } },
        { pane_id = "p-agent", rect = { x = 0, y = 0, width = 70, height = 60 } },
      },
      splits = {
        { id = "split_0_root", direction = "right", ratio = 0.35, rect = { x = 0, y = 0, width = 200, height = 60 } },
      },
    }
    local mi_exec, mi_log = mk_layout_fake(st_panes, mirror_layout, "t2", "p-nvim")
    utils.set_exec(mi_exec)
    panes.shrink_toggle("opencode")
    local mi_calls = resize_calls(mi_log)
    assert.truthy(
      #mi_calls == 1
        and mi_calls[1]["--pane"] == "p-agent"
        and mi_calls[1]["--direction"] == "right"
        and mi_calls[1]["--amount"] == "0.3300",
      "宽度 toggle：邻 pane 在左时方向镜像（agent 向右吃进）"
    )

    -- 镜像再按：nvim x=136 w=64（32%）→ 恢复 55%：直接向左扩张 nvim 自身
    -- nvim 是 root split 的右孩子：ratio 0.68（边界 x=136），nvim 占比 = 1−0.68 = 0.32
    local mr_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-agent", rect = { x = 0, y = 0, width = 136, height = 60 } },
        { pane_id = "p-nvim", rect = { x = 136, y = 0, width = 64, height = 60 } },
      },
      splits = {
        { id = "split_0_root", direction = "right", ratio = 0.68, rect = { x = 0, y = 0, width = 200, height = 60 } },
      },
    }
    local mr_exec, mr_log = mk_layout_fake(st_panes, mr_layout, "t2", "p-nvim")
    utils.set_exec(mr_exec)
    panes.shrink_toggle("opencode")
    local mr_calls = resize_calls(mr_log)
    assert.truthy(
      #mr_calls == 1
        and mr_calls[1]["--pane"] == "p-nvim"
        and mr_calls[1]["--direction"] == "left"
        and mr_calls[1]["--amount"] == "0.2300",
      "宽度 toggle：邻 pane 在左时再按恢复（nvim 向左扩张）"
    )

    -- 守卫：zoomed → 不 resize
    local zm_exec, zm_log =
      mk_layout_fake(st_panes, { zoomed = true, panes = layout_of(130, 70).panes }, "t2", "p-nvim")
    utils.set_exec(zm_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(zm_log) == 0, "宽度 toggle：zoomed 时拦截")

    -- 守卫：上下布局（左右都没有紧邻 pane）→ 不 resize
    -- fixture 带 direction=="down" 的 split：纵 split 不参与横向归属判定
    local stacked_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 200, height = 30 } },
        { pane_id = "p-agent", rect = { x = 0, y = 30, width = 200, height = 30 } },
      },
      splits = {
        { id = "split_0_root", direction = "down", ratio = 0.5, rect = { x = 0, y = 0, width = 200, height = 60 } },
      },
    }
    local sk_exec, sk_log = mk_layout_fake(st_panes, stacked_layout, "t2", "p-nvim")
    utils.set_exec(sk_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(sk_log) == 0, "宽度 toggle：上下布局（无左右紧邻）拦截")

    -- 守卫：tab 内只有 nvim 一个 pane → 无邻可推，不 resize
    local solo_layout = {
      zoomed = false,
      panes = { { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 244, height = 61 } } },
      splits = {},
    }
    local solo_exec, solo_log = mk_layout_fake(st_panes, solo_layout, "t2", "p-nvim")
    utils.set_exec(solo_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(solo_log) == 0, "宽度 toggle：tab 内仅 nvim 一个 pane 时拦截")

    -- 真实布局回归（实测 Herdr capture）：左右相邻 pane 之间有 1 列 divider ——
    -- nvim rect={x=0,y=0,width=134,height=61}，opencode rect={x=135,y=0,width=110,
    -- height=61}，area.width=245=134+1+110。精确边缘相等会误报「不相邻」，
    -- 相邻判定必须容忍 1 列分界线（0 间距布局仍兼容，见上文 layout_of 用例）
    local function divider_layout(nvim_w, agent_w)
      local total = nvim_w + 1 + agent_w
      return {
        zoomed = false,
        panes = {
          { pane_id = "p-nvim", rect = { x = 0, y = 0, width = nvim_w, height = 61 } },
          { pane_id = "p-agent", rect = { x = nvim_w + 1, y = 0, width = agent_w, height = 61 } },
        },
        splits = {
          {
            id = "split_0_root",
            direction = "right",
            ratio = nvim_w / total,
            rect = { x = 0, y = 0, width = total, height = 61 },
          },
        },
      }
    end

    -- 首按：root ratio = 134/245 ≈ 0.5469 → 收窄到 0.32（agent 在右 → direction
    -- left，amount = 0.5469−0.32 = 0.2269；旧 bug 公式按 pane 宽做分母会算 0.2292）
    local dv_exec, dv_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
    utils.set_exec(dv_exec)
    panes.shrink_toggle("opencode")
    local dv_calls = resize_calls(dv_log)
    assert.truthy(
      #dv_calls == 1
        and dv_calls[1]["--pane"] == "p-agent"
        and dv_calls[1]["--direction"] == "left"
        and dv_calls[1]["--amount"] == "0.2269",
      "宽度 toggle：1 列 divider 相邻（agent 右）首按收窄（真实布局回归）"
    )

    -- 成功的宽度调整屏幕直接可见，不弹通知；拦截类守卫仍提示（否则不知道为何没反应）
    local saved_notify = vim.notify
    local notify_log = {}
    vim.notify = function(msg)
      table.insert(notify_log, tostring(msg))
    end
    local q_exec, q_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
    utils.set_exec(q_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(
      #resize_calls(q_log) == 1 and #notify_log == 0,
      "宽度 toggle：成功收窄不弹通知（屏幕直接可见）"
    )
    local q2_exec, q2_log = mk_layout_fake(st_panes, divider_layout(78, 166), "t2", "p-nvim")
    utils.set_exec(q2_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(
      #resize_calls(q2_log) == 1 and #notify_log == 0,
      "宽度 toggle：成功恢复默认比例不弹通知"
    )
    local q3_exec, q3_log = mk_layout_fake(st_panes, stacked_layout, "t2", "p-nvim")
    utils.set_exec(q3_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(q3_log) == 0 and #notify_log >= 1, "宽度 toggle：不相邻拦截仍弹提示")
    vim.notify = saved_notify
    -- 再按：布局变为 nvim 78 / agent 166（x=79，仍隔 1 列）→ 恢复默认分屏比例 0.55
    -- （root ratio = 78/245 ≈ 0.3184 已在恢复死区 → 直接向右扩张 nvim 自身，
    -- amount = 0.55−0.3184 = 0.2316）
    local rv_exec, rv_log = mk_layout_fake(st_panes, divider_layout(78, 166), "t2", "p-nvim")
    utils.set_exec(rv_exec)
    panes.shrink_toggle("opencode")
    local rv_calls = resize_calls(rv_log)
    assert.truthy(
      #rv_calls == 1
        and rv_calls[1]["--pane"] == "p-nvim"
        and rv_calls[1]["--direction"] == "right"
        and rv_calls[1]["--amount"] == "0.2316",
      "宽度 toggle：1 列 divider 再按恢复默认分屏比例（扩张 nvim）"
    )

    -- 自愈回归：窄态（16%，曾被记成基准导致 16%↔32% 死循环）按压 → 直接切到
    -- 32%（实为放大 nvim），不记忆 16%；再按回到默认 55%（上例），而非 16%
    local nh_exec, nh_log = mk_layout_fake(st_panes, divider_layout(39, 205), "t2", "p-nvim")
    utils.set_exec(nh_exec)
    panes.shrink_toggle("opencode")
    local nh_calls = resize_calls(nh_log)
    assert.truthy(
      #nh_calls == 1
        and nh_calls[1]["--pane"] == "p-nvim"
        and nh_calls[1]["--direction"] == "right"
        and nh_calls[1]["--amount"] == "0.1608",
      "宽度 toggle：窄态 16% 按压自愈切到 32%（放大，不记窄基准）"
    )
    assert.truthy(vim.g.herd_shrink_state == nil, "宽度 toggle：窄态按压后仍不写 vim.g 基准")

    -- agent 在左镜像：agent x=0 w=110，nvim x=111 w=134 → 收窄 = agent 向右吃进
    -- nvim 是 root split 的右孩子：ratio 110/245 ≈ 0.4490（边界 x=110），amount
    -- = (1−0.32)−0.4490 = 0.2310
    local ml_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-agent", rect = { x = 0, y = 0, width = 110, height = 61 } },
        { pane_id = "p-nvim", rect = { x = 111, y = 0, width = 134, height = 61 } },
      },
      splits = {
        {
          id = "split_0_root",
          direction = "right",
          ratio = 110 / 245,
          rect = { x = 0, y = 0, width = 245, height = 61 },
        },
      },
    }
    local ml_exec, ml_log = mk_layout_fake(st_panes, ml_layout, "t2", "p-nvim")
    utils.set_exec(ml_exec)
    panes.shrink_toggle("opencode")
    local ml_calls = resize_calls(ml_log)
    assert.truthy(
      #ml_calls == 1
        and ml_calls[1]["--pane"] == "p-agent"
        and ml_calls[1]["--direction"] == "right"
        and ml_calls[1]["--amount"] == "0.2310",
      "宽度 toggle：1 列 divider 邻 pane 在左时方向镜像"
    )

    -- 镜像 divider 再按恢复：agent x=0 w=166，nvim x=167 w=78 → nvim 向左扩张
    -- ratio 166/245 ≈ 0.6776，nvim 占比 0.3224（恢复死区内）→ amount = 0.6776−0.45
    local ml2_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-agent", rect = { x = 0, y = 0, width = 166, height = 61 } },
        { pane_id = "p-nvim", rect = { x = 167, y = 0, width = 78, height = 61 } },
      },
      splits = {
        {
          id = "split_0_root",
          direction = "right",
          ratio = 166 / 245,
          rect = { x = 0, y = 0, width = 245, height = 61 },
        },
      },
    }
    local ml2_exec, ml2_log = mk_layout_fake(st_panes, ml2_layout, "t2", "p-nvim")
    utils.set_exec(ml2_exec)
    panes.shrink_toggle("opencode")
    local ml2_calls = resize_calls(ml2_log)
    assert.truthy(
      #ml2_calls == 1
        and ml2_calls[1]["--pane"] == "p-nvim"
        and ml2_calls[1]["--direction"] == "left"
        and ml2_calls[1]["--amount"] == "0.2276",
      "宽度 toggle：1 列 divider 镜像再按恢复（nvim 向左扩张）"
    )

    do -- 真实布局回归块（局部变量隔离，避免超出 200 局部上限）
      -- 真实布局回归（herdr 0.9.3 用户现场 capture，tab w6C:t1）：root ratio
      -- 0.32 × 宽 245 → 边界 78.4；herdr 取整落位（40 个真实 tab 布局标定）：
      -- 边界列 = round(rect.x+ratio*rect.width)，右孩子从该列起，左孩子右缘 =
      -- 该列−1（1 列 divider）→ nvim 右缘 77、右邻起 78。旧判定
      -- |nvim右缘−boundary|≤1 会算 |77−78.4|=1.4 把真实横向 split 排除，
      -- 误报「上下布局/独占 tab」
      local real_layout = {
        zoomed = false,
        panes = {
          { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 77, height = 61 } },
          { pane_id = "p-agent", rect = { x = 78, y = 0, width = 167, height = 61 } },
        },
        splits = {
          { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
        },
      }
      local rl_exec, rl_log = mk_layout_fake(st_panes, real_layout, "t2", "p-nvim")
      utils.set_exec(rl_exec)
      panes.shrink_toggle("opencode")
      st_calls = resize_calls(rl_log)
      assert.truthy(
        #st_calls == 1
          and st_calls[1]["--pane"] == "p-nvim"
          and st_calls[1]["--direction"] == "right"
          and st_calls[1]["--amount"] == "0.2300",
        "宽度 toggle：真实布局（边界 78.4，nvim 右缘 77）识别横向 split 并恢复 0.55"
      )

      -- 同 tab 后续形态（右侧 pane 再 split 出第二个 pane）：root 边界不变
      -- （78.4），nvim 归属仍是 root split；嵌套 split_1_1（边界 161.5）不参与
      -- nvim 的归属判定
      local grown_layout = {
        zoomed = false,
        panes = {
          { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 77, height = 61 } },
          { pane_id = "p-agent", rect = { x = 78, y = 0, width = 83, height = 61 } },
          { pane_id = "p-agent2", rect = { x = 162, y = 0, width = 83, height = 61 } },
        },
        splits = {
          { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
          { id = "split_1_1", direction = "right", ratio = 0.5, rect = { x = 78, y = 0, width = 167, height = 61 } },
        },
      }
      local gr_exec, gr_log = mk_layout_fake(st_panes, grown_layout, "t2", "p-nvim")
      utils.set_exec(gr_exec)
      panes.shrink_toggle("opencode")
      st_calls = resize_calls(gr_log)
      assert.truthy(
        #st_calls == 1
          and st_calls[1]["--pane"] == "p-nvim"
          and st_calls[1]["--direction"] == "right"
          and st_calls[1]["--amount"] == "0.2300",
        "宽度 toggle：右侧再 split 出新 pane 后仍调 root 边界（嵌套 split 不参与）"
      )

      -- 真实取整语义（默认比例 0.55）：边界 134.75 → round 135，nvim 右缘 134、
      -- agent 起 135。首按收窄：推 agent 向左吃进，amount = 0.55−0.32
      local rs_layout = {
        zoomed = false,
        panes = {
          { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 134, height = 61 } },
          { pane_id = "p-agent", rect = { x = 135, y = 0, width = 110, height = 61 } },
        },
        splits = {
          { id = "split_0_root", direction = "right", ratio = 0.55, rect = { x = 0, y = 0, width = 245, height = 61 } },
        },
      }
      local rs_exec, rs_log = mk_layout_fake(st_panes, rs_layout, "t2", "p-nvim")
      utils.set_exec(rs_exec)
      panes.shrink_toggle("opencode")
      st_calls = resize_calls(rs_log)
      assert.truthy(
        #st_calls == 1
          and st_calls[1]["--pane"] == "p-agent"
          and st_calls[1]["--direction"] == "left"
          and st_calls[1]["--amount"] == "0.2300",
        "宽度 toggle：真实取整语义（边界 134.75）首按收窄（agent 吃进）"
      )

      -- 真实取整语义镜像（nvim 是右孩子）：边界 78.4 → round 78 = nvim x，左邻
      -- 右缘 77。share = 1−0.32 = 0.68 → 收窄到 0.32：推左邻向右，amount = 0.36
      local rm_layout = {
        zoomed = false,
        panes = {
          { pane_id = "p-agent", rect = { x = 0, y = 0, width = 77, height = 61 } },
          { pane_id = "p-nvim", rect = { x = 78, y = 0, width = 167, height = 61 } },
        },
        splits = {
          { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
        },
      }
      local rm_exec, rm_log = mk_layout_fake(st_panes, rm_layout, "t2", "p-nvim")
      utils.set_exec(rm_exec)
      panes.shrink_toggle("opencode")
      st_calls = resize_calls(rm_log)
      assert.truthy(
        #st_calls == 1
          and st_calls[1]["--pane"] == "p-agent"
          and st_calls[1]["--direction"] == "right"
          and st_calls[1]["--amount"] == "0.3600",
        "宽度 toggle：真实取整语义镜像（nvim 右孩子，边界 78.4 = nvim x）收窄"
      )

      -- 真实取整语义嵌套：root 边界 98（p-left 右缘 97），嵌套 split_1 边界
      -- 171.5 → round 172 = nvim x（p-mid 右缘 171）。nvim 只匹配 split_1（root
      -- 边界 98 离 nvim 很远），share = 1−0.5 = 0.5 → 收窄：推 p-mid 向右，
      -- amount = 0.68−0.5 = 0.18
      local rn_layout = {
        zoomed = false,
        panes = {
          { pane_id = "p-left", rect = { x = 0, y = 0, width = 97, height = 61 } },
          { pane_id = "p-mid", rect = { x = 98, y = 0, width = 73, height = 61 } },
          { pane_id = "p-nvim", rect = { x = 172, y = 0, width = 73, height = 61 } },
        },
        splits = {
          { id = "split_0_root", direction = "right", ratio = 0.4, rect = { x = 0, y = 0, width = 245, height = 61 } },
          { id = "split_1", direction = "right", ratio = 0.5, rect = { x = 98, y = 0, width = 147, height = 61 } },
        },
      }
      local rn_exec, rn_log = mk_layout_fake(st_panes, rn_layout, "t2", "p-nvim")
      utils.set_exec(rn_exec)
      panes.shrink_toggle("opencode")
      st_calls = resize_calls(rn_log)
      assert.truthy(
        #st_calls == 1
          and st_calls[1]["--pane"] == "p-mid"
          and st_calls[1]["--direction"] == "right"
          and st_calls[1]["--amount"] == "0.1800",
        "宽度 toggle：真实取整语义嵌套（取内层 split_1 边界，非 root）"
      )
    end
    -- 守卫：最近邻 gap > 1（≥2 列，无法归因于分界线，布局异常）→ 不 resize
    local g2_layout = divider_layout(134, 110)
    g2_layout.panes[2].rect.x = 136 -- nvim 右缘 134，agent 左缘 136
    local g2_exec, g2_log = mk_layout_fake(st_panes, g2_layout, "t2", "p-nvim")
    utils.set_exec(g2_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(g2_log) == 0, "宽度 toggle：gap>1（2 列）拦截不 resize")

    -- 守卫：rect 重叠（边缘 gap 为负，布局异常）→ 不 resize
    local ov_layout = divider_layout(134, 110)
    ov_layout.panes[2].rect.x = 100
    local ov_exec, ov_log = mk_layout_fake(st_panes, ov_layout, "t2", "p-nvim")
    utils.set_exec(ov_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(#resize_calls(ov_log) == 0, "宽度 toggle：pane rect 重叠时拦截")

    -- 多 pane（中间隔无关 pane）：nvim 推的是归属 root split 的边界（nvim|other
    -- 分界），与更远的 agent 无关。root ratio = 100/245 ≈ 0.4082 →
    -- amount = 0.4082−0.32 = 0.0882（旧 bug 公式按 pane 宽做分母会算 0.1555）
    local mid_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 100, height = 61 } },
        { pane_id = "p-other", rect = { x = 101, y = 0, width = 43, height = 61 } },
        { pane_id = "p-agent", rect = { x = 145, y = 0, width = 100, height = 61 } },
      },
      splits = {
        {
          id = "split_0_root",
          direction = "right",
          ratio = 100 / 245,
          rect = { x = 0, y = 0, width = 245, height = 61 },
        },
        { id = "split_1", direction = "right", ratio = 43 / 144, rect = { x = 101, y = 0, width = 144, height = 61 } },
      },
    }
    local mid_exec, mid_log = mk_layout_fake(st_panes, mid_layout, "t2", "p-nvim")
    utils.set_exec(mid_exec)
    panes.shrink_toggle("opencode")
    local mid_calls = resize_calls(mid_log)
    assert.truthy(
      #mid_calls == 1
        and mid_calls[1]["--pane"] == "p-other"
        and mid_calls[1]["--direction"] == "left"
        and mid_calls[1]["--amount"] == "0.0882",
      "宽度 toggle：中间隔无关 pane 时调 nvim|紧邻 分界（归属 split 的 ratio 语义）"
    )

    -- 多 pane：右侧上下堆叠列（agent pane 又 split 出新 pane 的形态）——
    -- nvim 全高在左，右列两 pane 共享同一条竖直分界，推任一个都移动整列边界。
    -- 边界属于 root split：ratio = 134/245 ≈ 0.5469 → amount = 0.5469−0.32 =
    -- 0.2269（同两 pane divider 布局，与列内成员宽度无关）；邻居取 gap 最小再最
    -- 靠上（p-agent）
    local col_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 134, height = 61 } },
        { pane_id = "p-agent", rect = { x = 135, y = 0, width = 110, height = 30 } },
        { pane_id = "p-agent2", rect = { x = 135, y = 31, width = 110, height = 30 } },
      },
      splits = {
        {
          id = "split_0_root",
          direction = "right",
          ratio = 134 / 245,
          rect = { x = 0, y = 0, width = 245, height = 61 },
        },
        { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 135, y = 0, width = 110, height = 61 } },
      },
    }
    local co_exec, co_log = mk_layout_fake(st_panes, col_layout, "t2", "p-nvim")
    utils.set_exec(co_exec)
    panes.shrink_toggle("opencode")
    local co_calls = resize_calls(co_log)
    assert.truthy(
      #co_calls == 1
        and co_calls[1]["--pane"] == "p-agent"
        and co_calls[1]["--direction"] == "left"
        and co_calls[1]["--amount"] == "0.2269",
      "宽度 toggle：右侧堆叠列（多 pane）收窄 nvim（推整列边界，amount 只看归属 split 的 ratio）"
    )

    -- 堆叠列再按恢复：nvim 78 / 列 166×2（root ratio = 78/245 ≈ 0.3184 已在恢复
    -- 死区）→ 直接扩张 nvim：amount = 0.55−0.3184 = 0.2316
    local col2_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 78, height = 61 } },
        { pane_id = "p-agent", rect = { x = 79, y = 0, width = 166, height = 30 } },
        { pane_id = "p-agent2", rect = { x = 79, y = 31, width = 166, height = 30 } },
      },
      splits = {
        {
          id = "split_0_root",
          direction = "right",
          ratio = 78 / 245,
          rect = { x = 0, y = 0, width = 245, height = 61 },
        },
        { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 79, y = 0, width = 166, height = 61 } },
      },
    }
    local co2_exec, co2_log = mk_layout_fake(st_panes, col2_layout, "t2", "p-nvim")
    utils.set_exec(co2_exec)
    panes.shrink_toggle("opencode")
    local co2_calls = resize_calls(co2_log)
    assert.truthy(
      #co2_calls == 1
        and co2_calls[1]["--pane"] == "p-nvim"
        and co2_calls[1]["--direction"] == "right"
        and co2_calls[1]["--amount"] == "0.2316",
      "宽度 toggle：右侧堆叠列（多 pane）再按恢复（直接扩张 nvim，回到 55% 占比）"
    )

    -- L 形布局回归（实测复现场景）：邻 pane 不占满 split 对侧（中间隔列）时，
    -- 旧 bug 公式（pane 宽做分母）会系统性过冲 —— 预期落 0.32 实际落 0.2667。
    -- amount 语义 = 被推边界所属 split 的 ratio 增量：nvim|右列 分界属于 root
    -- split（ratio 0.45，边界 x=54）→ 收窄 0.32 = ratio − 0.13，推 p-mid（右列
    -- 里 gap 最小且最靠上的成员，代理整列边界）
    local lshrink_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 54, height = 40 } },
        { pane_id = "p-mid", rect = { x = 54, y = 0, width = 33, height = 20 } },
        { pane_id = "p-mid2", rect = { x = 87, y = 0, width = 33, height = 20 } },
        { pane_id = "p-agent", rect = { x = 54, y = 20, width = 66, height = 20 } },
      },
      splits = {
        { id = "split_0_root", direction = "right", ratio = 0.45, rect = { x = 0, y = 0, width = 120, height = 40 } },
        { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 54, y = 0, width = 66, height = 40 } },
        { id = "split_2", direction = "right", ratio = 0.5, rect = { x = 54, y = 0, width = 66, height = 20 } },
      },
    }
    local ls_exec, ls_log = mk_layout_fake(st_panes, lshrink_layout, "t2", "p-nvim")
    utils.set_exec(ls_exec)
    panes.shrink_toggle("opencode")
    local ls_calls = resize_calls(ls_log)
    assert.truthy(
      #ls_calls == 1
        and ls_calls[1]["--pane"] == "p-mid"
        and ls_calls[1]["--direction"] == "left"
        and ls_calls[1]["--amount"] == "0.1300",
      "宽度 toggle：L 形布局收窄（amount = 归属 split ratio 0.45−0.32；旧公式 0.1793 过冲）"
    )

    -- L 形从 0.32 恢复：root ratio 已是 0.32（恢复死区内）→ 推 nvim 自身 right，
    -- amount = 0.55−0.32 = 0.23
    local lrestore_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 38.4, height = 40 } },
        { pane_id = "p-mid", rect = { x = 38.4, y = 0, width = 40.8, height = 20 } },
        { pane_id = "p-mid2", rect = { x = 79.2, y = 0, width = 40.8, height = 20 } },
        { pane_id = "p-agent", rect = { x = 38.4, y = 20, width = 81.6, height = 20 } },
      },
      splits = {
        { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 120, height = 40 } },
        { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 38.4, y = 0, width = 81.6, height = 40 } },
        { id = "split_2", direction = "right", ratio = 0.5, rect = { x = 38.4, y = 0, width = 81.6, height = 20 } },
      },
    }
    local lr_exec, lr_log = mk_layout_fake(st_panes, lrestore_layout, "t2", "p-nvim")
    utils.set_exec(lr_exec)
    panes.shrink_toggle("opencode")
    local lr_calls = resize_calls(lr_log)
    assert.truthy(
      #lr_calls == 1
        and lr_calls[1]["--pane"] == "p-nvim"
        and lr_calls[1]["--direction"] == "right"
        and lr_calls[1]["--amount"] == "0.2300",
      "宽度 toggle：L 形布局从收窄锚点恢复（推 nvim 自身 right，amount 0.55−0.32）"
    )

    -- 落点校验：resize 响应内嵌新 layout 时核对实际占比 —— 服务端最小宽度 clamp
    -- 把 root ratio 只推到 0.40（没到 0.32）→ warn；响应无 layout 字段（上文各
    -- fake 的现状）→ 静默跳过
    local clamped_layout = divider_layout(134, 110)
    clamped_layout.splits[1].ratio = 0.40
    local saved_notify2 = vim.notify
    local notify_log2 = {}
    vim.notify = function(msg)
      table.insert(notify_log2, tostring(msg))
    end
    local cl_exec, cl_log =
      mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim", { changed = true, layout = clamped_layout })
    utils.set_exec(cl_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(
      #resize_calls(cl_log) == 1 and #notify_log2 == 1,
      "宽度 toggle：clamp 未达目标时告警（响应内嵌 layout，实际 40% ≠ 目标 32%）"
    )
    local ncl_exec, ncl_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
    utils.set_exec(ncl_exec)
    panes.shrink_toggle("opencode")
    assert.truthy(
      #resize_calls(ncl_log) == 1 and #notify_log2 == 1,
      "宽度 toggle：响应无 layout 字段时静默跳过落点校验"
    )
    vim.notify = saved_notify2

    -- 取最内层归属 split：nvim 同时落在 root（ratio 0.4，边界 x=80）与嵌套右
    -- split_1（ratio 0.5，边界 x=140）内 → 取 rect 面积最小者 split_1（nvim 直接
    -- 控制的边界），share = 0.5 → amount = 0.5−0.32 = 0.18，推右邻 p-agent。
    -- 若误选 root（右孩子，share 0.6）会推 p-left 且 amount 0.28，断言即失败
    local nested_layout = {
      zoomed = false,
      panes = {
        { pane_id = "p-left", rect = { x = 0, y = 0, width = 80, height = 60 } },
        { pane_id = "p-nvim", rect = { x = 80, y = 0, width = 60, height = 60 } },
        { pane_id = "p-agent", rect = { x = 140, y = 0, width = 60, height = 60 } },
      },
      splits = {
        { id = "split_0_root", direction = "right", ratio = 0.4, rect = { x = 0, y = 0, width = 200, height = 60 } },
        { id = "split_1", direction = "right", ratio = 0.5, rect = { x = 80, y = 0, width = 120, height = 60 } },
      },
    }
    local ns_exec, ns_log = mk_layout_fake(st_panes, nested_layout, "t2", "p-nvim")
    utils.set_exec(ns_exec)
    panes.shrink_toggle("opencode")
    local ns_calls = resize_calls(ns_log)
    assert.truthy(
      #ns_calls == 1
        and ns_calls[1]["--pane"] == "p-agent"
        and ns_calls[1]["--direction"] == "left"
        and ns_calls[1]["--amount"] == "0.1800",
      "宽度 toggle：嵌套布局取最内层归属 split（推 split_1 的边界，非 root 边界）"
    )

    -- 集成：命令已注册、默认不绑键、toggle_ratio 默认 0.35、绑定后生效
    assert.truthy(vim.api.nvim_get_commands({})["HerdrShrinkToggle"] ~= nil, ":HerdrShrinkToggle 已创建")
    assert.truthy(not has_map(" h<", "n"), "默认不绑定 <leader>h<")
    assert.truthy(
      math.abs(require("herder-agents.config").options.toggle_ratio - 0.32) < 1e-9,
      "toggle_ratio 默认 0.32"
    )
    plugin.setup({
      tools = { mycli = { title = " My CLI Chat " } },
      keys = { shrink_toggle = "<leader>h<" },
    })
    assert.truthy(has_map(" h<", "n"), "传入 shrink_toggle 键后注册 <leader>h<")

    utils.set_exec(nil)
    utils.set_exec_async(nil)
    if saved_env then
      vim.env.HERDR_ENV = saved_env
    else
      vim.env.HERDR_ENV = nil
    end
  end)
end)
