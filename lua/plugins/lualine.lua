return {
  'nvim-lualine/lualine.nvim',
  event = "VimEnter",
  dependencies = { 'nvim-tree/nvim-web-devicons' }, -- Обязательно для иконок!
  opts = {
    options = {
      icons_enabled = true,
      theme = 'auto',
      component_separators = { '', '' },
      section_separators = { '', '' },
      disabled_filetypes = {
        statusline = {},
        winbar = {},
      },
      ignore_focus = {},
      always_last_session = true,
      globalstatus = true,
    },
    sections = {
      lualine_a = {'mode'},
      lualine_b = {'branch', 'diff', 'diagnostics'},
      lualine_c = {'filename'},
      lualine_y = {'progress'},
      lualine_z = {'location'},
    },
  },
}
