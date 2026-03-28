-- Test helpers for mini.test
local Helpers = {}

-- Extend with expectations
Helpers = vim.tbl_extend("error", Helpers, require("tests.expectations"))

---Start a child Neovim process for testing
---@param child table MiniTest child neovim instance
function Helpers.child_start(child)
  child.restart({ "-u", "tests/nvim_init.lua" })
  child.o.statusline = ""
  child.o.laststatus = 0
  child.o.cmdheight = 0
end

---Setup codecompanion in child process
---@param child table
---@param config? table
function Helpers.setup_codecompanion(child, config)
  config = config or {}
  child.lua([[
    local config = require("tests.config")
    require("codecompanion").setup(config)
  ]])
end

---Create a temporary directory
---@return string path
function Helpers.temp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---Clean up a directory
---@param path string
function Helpers.cleanup_dir(path)
  if path and vim.uv.fs_stat(path) then
    vim.fn.delete(path, "rf")
  end
end

---Wait for a condition to be true
---@param condition function Condition to check
---@param timeout? number Timeout in milliseconds (default 1000)
---@param interval? number Check interval in milliseconds (default 50)
---@return boolean success
function Helpers.wait_for(condition, timeout, interval)
  timeout = timeout or 1000
  interval = interval or 50
  local start = vim.uv.hrtime() / 1e6

  while (vim.uv.hrtime() / 1e6) - start < timeout do
    if condition() then
      return true
    end
    vim.wait(interval)
  end

  return false
end

return Helpers
