return {
    {
        dir = vim.fn.stdpath("config") .. "/lua/custom/import-rename",
        name = "import-rename",
        event = "VeryLazy",
        config = function()
            require("custom.import-rename").setup()
        end,
    },
}
