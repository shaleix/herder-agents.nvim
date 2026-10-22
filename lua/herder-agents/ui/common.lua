local M = {}

-- 合成「浮窗底 + 常规前景」：直接 link NormalFloat 会把弹窗正文染成主题的
-- 浮窗灰（多数主题 NormalFloat.fg 刻意比 Normal.fg 暗一档，为浮窗次要内容设计），
-- 故取 NormalFloat.bg + Normal.fg 现算（同 question_form 的 HerderQFormNormal 思路）；
-- 取不到色（headless/无色主题）则回落 link NormalFloat 保底。
-- setup 与 ColorScheme 后各算一次，跟随主题切换。
local function define_float_normal()
  local ok_f, f = pcall(vim.api.nvim_get_hl, 0, { name = "NormalFloat", link = false })
  local ok_n, n = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  local composed = (ok_f and type(f) == "table" and f.bg) and { bg = f.bg } or {}
  if ok_n and type(n) == "table" and n.fg then
    composed.fg = n.fg
  end
  if next(composed) ~= nil then
    vim.api.nvim_set_hl(0, "HerderFloatNormal", composed)
  else
    vim.api.nvim_set_hl(0, "HerderFloatNormal", { link = "NormalFloat", default = true })
  end
end

local hl_autocmd_bound = false

-- UI 高亮的兜底定义（default = true，不覆盖用户/主题已有的定义）
-- 组名沿用原配置（aider 风格），已有主题定义可无缝接管；
-- HerderFloatNormal 例外：不走 link，见上方 define_float_normal
M.setup_highlights = function()
  local defs = {
    HerderFloatBorder = { link = "FloatBorder" },
    AiderFolder = { link = "Directory" },
    AiderPromptTitle = { link = "FloatTitle" },
    AiderComment = { link = "Comment" },
    -- 备注（notes）：侧栏 sign、行尾虚拟文本预览，以及 Chat 树里的勾选框/位置/内容
    HerderNoteSign = { link = "DiagnosticSignInfo" },
    HerderNoteVirt = { link = "Comment" },
    HerderNoteChecked = { link = "String" },
    HerderNoteUnchecked = { link = "LineNr" },
    HerderNoteLoc = { link = "Directory" },
    HerderNoteText = { link = "Normal" },
  }
  for name, def in pairs(defs) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
  end
  define_float_normal()
  -- 主题切换后重算合成色（ColorScheme 在新主题高亮应用后触发）；
  -- 只绑一次，setup 重复调用不叠加 autocmd
  if not hl_autocmd_bound then
    hl_autocmd_bound = true
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("HerderAgentsFloatHl", { clear = true }),
      callback = define_float_normal,
    })
  end
end

-- 弹窗宽度上限：不超过当前 neovim 可见宽度的 90%
M.clamp_popup_width = function(width)
  if type(width) ~= "number" then
    return width
  end
  return math.min(width, math.floor(vim.o.columns * 0.9))
end

local blend = 50

local active_backdrop = nil

-- 全屏遮罩：挂到指定 buffer 的生命周期上；返回 close 函数。
-- 供本插件弹窗与外部（如 neogit）复用：
--   require("herder-agents.ui.common").dim(bufnr)
--
-- 遮罩是全屏唯一的，多个弹窗（如 history -> chat 回填）会共享同一个遮罩，
-- 用引用计数跟踪绑定的 buffer：全部关闭后才真正关闭遮罩，
-- 避免先关的弹窗把后开弹窗的遮罩一起带走。
M.dim = function(bufnr, events)
  local backdrop_name = "HerderAgentsBackdrop"

  local zindex = 50

  -- 挂到指定 buffer 生命周期上（once，多个绑定谁先触发都安全）
  local function bind_buf_lifecycle(b, bd)
    if b ~= nil and vim.api.nvim_buf_is_valid(b) then
      bd.refs[b] = true
      vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden", "BufWipeout" }, {
        buffer = b,
        once = true,
        callback = function()
          bd.refs[b] = nil
          if next(bd.refs) == nil then
            bd.close()
          end
        end,
      })
    end
  end

  -- 重复调用复用已有遮罩，只补绑新 buffer 的生命周期
  if active_backdrop then
    bind_buf_lifecycle(bufnr, active_backdrop)
    return active_backdrop.close
  end

  local backdrop_bufnr = vim.api.nvim_create_buf(false, true)
  local winnr = vim.api.nvim_open_win(backdrop_bufnr, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines - 1, -- 底部留出一行，不遮住 statusline
    focusable = false,
    style = "minimal",
    border = "none", -- 覆盖全局 vim.o.winborder，避免遮罩出现边框
    zindex = zindex - 1, -- ensure it's below the reference window
  })

  vim.api.nvim_set_hl(0, backdrop_name, { bg = "#000000", default = true })
  vim.wo[winnr].winhighlight = "Normal:" .. backdrop_name
  vim.wo[winnr].winblend = blend
  vim.bo[backdrop_bufnr].buftype = "nofile"

  local closed = false
  local function close_dim()
    if closed then
      return
    end
    closed = true
    active_backdrop = nil
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
    if vim.api.nvim_buf_is_valid(backdrop_bufnr) then
      vim.api.nvim_buf_delete(backdrop_bufnr, { force = true })
    end
  end

  active_backdrop = { close = close_dim, refs = {} }

  if events ~= nil then
    vim.api.nvim_create_autocmd(events, {
      once = true,
      callback = function()
        close_dim()
      end,
    })
  end

  -- 把遮罩生命周期绑定到被 dim 的 buffer 上，而不是某个会变的窗口 id。
  -- 浮窗在刷新时可能被重建（窗口 id 变化），用窗口 id 匹配会导致遮罩残留。
  bind_buf_lifecycle(bufnr, active_backdrop)

  return close_dim
end

return M
