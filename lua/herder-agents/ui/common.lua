local M = {}

-- UI 高亮的兜底定义（default = true，不覆盖用户/主题已有的定义）
-- 组名沿用原配置（aider 风格），已有主题定义可无缝接管
M.setup_highlights = function()
  local defs = {
    AiderInputFloatNormal = { link = "NormalFloat" },
    AiderInputFloatBorder = { link = "FloatBorder" },
    AiderFolder = { link = "Directory" },
    AiderPromptTitle = { link = "FloatTitle" },
    AiderComment = { link = "Comment" },
  }
  for name, def in pairs(defs) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
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
M.dim = function(bufnr, events)
  local backdrop_name = "HerderAgentsBackdrop"

  local zindex = 50

  -- 挂到指定 buffer 生命周期上（once，多个绑定谁先触发都安全）
  local function bind_buf_lifecycle(b)
    if b ~= nil and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden", "BufWipeout" }, {
        buffer = b,
        once = true,
        callback = function()
          if active_backdrop then
            active_backdrop.close()
          end
        end,
      })
    end
  end

  -- 遮罩是全屏唯一的，重复调用复用已有遮罩，只补绑新 buffer 的生命周期
  if active_backdrop then
    bind_buf_lifecycle(bufnr)
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

  active_backdrop = { close = close_dim }

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
  bind_buf_lifecycle(bufnr)

  return close_dim
end

return M
