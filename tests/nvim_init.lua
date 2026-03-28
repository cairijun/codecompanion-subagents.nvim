-- Neovim init.lua for testing with mini.test
-- Sets up runtime path and loads required dependencies

-- Add dependencies to runtime path FIRST (so they are searched first for codecompanion)
vim.opt.rtp:append("deps/mini.nvim")
vim.opt.rtp:append("deps/plenary.nvim")
vim.opt.rtp:append("deps/nvim-treesitter")
vim.opt.rtp:append("deps/codecompanion.nvim")

-- Set current project to runtime path AFTER codecompanion (so our _extensions override)
vim.opt.rtp:append(vim.fn.getcwd())

-- Setup mini.test
require("mini.test").setup()

-- Install and setup Tree-sitter
require("nvim-treesitter").setup({
  install_dir = "deps/parsers",
})

local ok, msg = require("nvim-treesitter")
  .install({
    "lua",
    "make",
    "markdown",
    "markdown_inline",
    "yaml",
  }, { summary = true, max_jobs = 10 })
  :wait(1800000)

assert(ok, "Failed to install Tree-sitter parsers: " .. tostring(msg))
