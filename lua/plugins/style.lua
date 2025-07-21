return {
    {
        "catppuccin/nvim",
        name = "catppuccin",
        priority = 1000, -- <-- Вот здесь должна быть запятая
        config = function()
            vim.cmd([[colorscheme catppuccin-mocha]])
        end,
    }
}
