return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = 'master',
    event = { "BufReadPre", "BufNewFile" },
    build = ":TSUpdate",

    config = function()
      require('nvim-treesitter.configs').setup {
        ensure_installed = { "lua", "vim", "vimdoc"},
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
        },
      }
    end
  }
}
