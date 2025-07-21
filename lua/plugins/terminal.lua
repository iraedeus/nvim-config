return {
    'akinsho/toggleterm.nvim',
    version = "*",
    config = function()
        require('toggleterm').setup({
            open_mapping = [[<c-\>]],
            direction = 'horizontal',
            size = 15,
            start_in_insert = true,
            hide_numbers = true,
            close_on_exit = true,
        })

        function _G.set_terminal_keymaps()
            vim.keymap.set('t', '<esc>', [[<C-\><C-n>]], { noremap = true })
        end

        vim.cmd('autocmd! TermOpen term://* lua set_terminal_keymaps()')
    end,
}
