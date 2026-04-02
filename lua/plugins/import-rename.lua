return {
    {
        name = "import-rename",
        dir = vim.fn.stdpath("config") .. "/lua/custom/import-rename",
        config = function()
            require("custom.import-rename").setup()
        end,
    }
}
