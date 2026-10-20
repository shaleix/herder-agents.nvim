---@mod herder-agents.ui.visible_files 可见文件挑选器编排（fzf-lua 优先）
--
-- :AIVisibleFiles 入口：取当前工具的 agent pane 可见视口 → 提取真实存在的
-- 文件候选（含 file:line[:col]）→ fzf-lua files provider 挑选打开；
-- 无可见候选时回退仓库文件列表，fzf-lua 未安装/缺 fzf binary 时回退 vim.ui.select。
-- :AIVisibleFiles! 输出完整诊断（pane 选择、cwd/root、捕获文本、仓库索引、
-- 逐 token 解析、picker 分支），零候选时也会自动输出，供定位“为什么没匹配”。

local M = {}

-- fzf-lua 模块在但 fzf binary 缺失：只提示一次（否则每次调用都刷屏）
local warned_missing_fzf = false

function M.open(opts)
  opts = opts or {}
  local debug = opts.debug == true

  local config = require("herder-agents.config")
  local panes = require("herder-agents.panes")
  local utils = require("herder-agents.utils")
  local vf = require("herder-agents.visible_files")

  local logs = {}
  local function log(fmt, ...)
    if select("#", ...) > 0 then
      logs[#logs + 1] = string.format(fmt, ...)
    else
      logs[#logs + 1] = fmt
    end
  end

  -- 诊断输出：完整日志写文件；:messages 只显示前 120 行（避免刷屏）
  local function emit()
    if #logs == 0 then
      return
    end
    local path = vim.fn.tempname() .. ".visible-files.log"
    vim.fn.writefile(logs, path)
    local shown = logs
    if #logs > 180 then
      -- 中段逐 token 日志只进文件；:messages 保留头（pane/capture/repo）+ 尾
      -- （candidates / picker 分支），方便一眼看到关键结论
      shown = vim.list_slice(logs, 1, 100)
      shown[#shown + 1] = ("... (%d more lines; full log: %s)"):format(#logs - 160, path)
      vim.list_extend(shown, vim.list_slice(logs, #logs - 59, #logs))
    end
    vim.api.nvim_echo({ { table.concat(shown, "\n"), "None" } }, true, {})
    utils.info("AIVisibleFiles diagnostics → " .. path)
  end

  local function log_panes()
    local list = utils.herdr_json("pane", "list")
    local ps = list and list.result and list.result.panes or {}
    if type(ps) ~= "table" then
      log("  pane list unreadable")
      return
    end
    for _, p in ipairs(ps) do
      log(
        "  pane=%s label=%s agent=%s tab=%s cwd=%s focused=%s",
        tostring(p.pane_id),
        tostring(p.label),
        tostring(p.agent),
        tostring(p.tab_id),
        tostring(p.foreground_cwd or p.cwd),
        tostring(p.focused)
      )
    end
  end

  log("visible_files %s", vf.VERSION)
  log(
    "env: HERDR_ENV=%s HERDR_TAB_ID=%s HERDR_PANE_ID=%s",
    tostring(vim.env.HERDR_ENV),
    tostring(vim.env.HERDR_TAB_ID),
    tostring(vim.env.HERDR_PANE_ID)
  )

  local tool = config.current_tool()
  log("current_tool=%s", tostring(tool))
  local pane = panes.lookup(tool)
  if not pane then
    log("pane: not found (tool=%s)", tostring(tool))
    if debug then
      log("pane list:")
      log_panes()
      emit()
    end
    utils.err(tool .. " pane not found; toggle it first")
    return
  end
  log(
    "pane=%s label=%s agent=%s tab=%s focused=%s",
    tostring(pane.pane_id),
    tostring(pane.label),
    tostring(pane.agent),
    tostring(pane.tab_id),
    tostring(pane.focused)
  )
  log("pane.cwd=%s pane.foreground_cwd=%s", tostring(pane.cwd), tostring(pane.foreground_cwd))
  if debug then
    log("pane list:")
    log_panes()
  end

  local cwd = pane.foreground_cwd or pane.cwd or vim.fn.getcwd()
  local root = vf.search_root(cwd)
  log("cwd=%s", tostring(cwd))
  log("search_root=%s", tostring(root))

  local text = vf.capture(pane.pane_id)
  if not text then
    log("capture: FAILED (herdr pane read non-zero)")
    if debug then
      emit()
    end
    utils.err("herdr pane read failed")
    return
  end
  local clean = vf.strip_ansi(text)
  log("capture: bytes=%d lines=%d stripped_bytes=%d", #text, #vim.split(text, "\n", { plain = true }), #clean)

  local repo = vf.repo_files(root)
  log("repo: %d entries via %s", #repo, tostring(vf.last_repo_source))

  local candidates = vf.extract_visible_candidates(clean, repo, root, cwd)
  local need_diag = debug or #candidates == 0
  if need_diag then
    log("capture file: %s", vf.dump_text(clean, "visible-capture"))
    for i = 1, math.min(#repo, 20) do
      log("  repo[%d] %s", i, repo[i])
    end
    -- 重跑一次带逐行/逐 token 日志（首次结果不变，用第二次的返回值）
    candidates = vf.extract_visible_candidates(clean, repo, root, cwd, { log = log })
  end
  log("candidates: %d", #candidates)
  for i, c in ipairs(candidates) do
    log("  [%d] %s", i, c)
  end

  -- fzf-lua 惰性 require（headless 测试可经 package.preload 注入 stub）；
  -- 模块存在还不够：缺 fzf binary 时 fzf-lua 会 abort，必须走 utils.fzf_available()
  local ok_fzf, fzf = pcall(require, "fzf-lua")
  local use_fzf = ok_fzf and utils.fzf_available()
  log("fzf: module=%s available=%s", tostring(ok_fzf), tostring(use_fzf))
  if ok_fzf and not use_fzf and not warned_missing_fzf then
    warned_missing_fzf = true
    utils.warn("fzf executable not found; install fzf for the fzf-lua picker (using vim.ui.select)")
  end

  local branch, tmp
  if use_fzf and #candidates > 0 then
    branch = "fzf-visible"
    tmp = vim.fn.tempname()
    vim.fn.writefile(candidates, tmp)
    log("picker: fzf files (tmp=%s)", tmp)
  elseif use_fzf and #repo > 0 then
    branch = "fzf-repo-fallback"
    log("picker: fzf repo fallback")
  elseif #candidates > 0 then
    branch = "select-visible"
    log("picker: vim.ui.select (visible)")
  elseif #repo > 0 then
    branch = "select-repo"
    log("picker: vim.ui.select (repo fallback)")
  else
    branch = "empty"
    log("picker: empty (no candidates, no repo files)")
  end

  -- 诊断先输出：picker 会接管焦点，日志留在 :messages / 文件里
  if need_diag then
    emit()
  end

  local function pick_open(entries, prompt)
    utils.pick(entries, prompt, function(choice)
      if choice then
        vf.open_target(choice, cwd, root)
      end
    end)
  end

  if branch == "fzf-visible" then
    -- 复用 files provider（预览 / 图标 / file:line:col 直达都来自 provider 自带
    -- 行为）：候选逐行写入临时文件，cmd 用 cat 喂给 fzf；on_close 清理临时文件
    local ok_call = pcall(fzf.files, {
      cwd = root,
      cmd = "cat " .. vim.fn.shellescape(tmp),
      prompt = "Visible files> ",
      winopts = {
        title = " Visible files ",
        on_close = function()
          pcall(os.remove, tmp)
        end,
      },
    })
    if ok_call then
      return
    end
    pcall(os.remove, tmp)
    pick_open(candidates, "Visible files> ")
    return
  end

  if branch == "fzf-repo-fallback" then
    -- 无可见候选：回退正常 fd/rg provider 列仓库文件
    local ok_call = pcall(fzf.files, {
      cwd = root,
      prompt = "No visible files — repo files> ",
      winopts = { title = " Repo files (fallback) " },
    })
    if ok_call then
      return
    end
    pick_open(repo, "No visible files — repo files> ")
    return
  end

  if branch == "select-visible" then
    pick_open(candidates, "Visible files> ")
  elseif branch == "select-repo" then
    pick_open(repo, "No visible files — repo files> ")
  else
    utils.info("No files found in repo")
  end
end

return M
