return {
    'akinsho/toggleterm.nvim',
    version = "*",
    keys = {
        {
            [[<c-\>]],
            "<cmd>ToggleTerm<cr>",
            desc = "Toggle terminal"
        },
    },
    config = function()
        function _G.set_terminal_keymaps()
            vim.keymap.set('t', '<esc>', [[<C-\><C-n>]], { noremap = true })
        end

        vim.cmd('autocmd! TermOpen term://* lua set_terminal_keymaps()')
    end,
}
