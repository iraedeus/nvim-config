return {
    {
        'lervag/vimtex',
        config = function()
            vim.g.vimtex_view_method = 'zathura'
            vim.g.vimtex_compiler_method = 'lualatex'

            vim.g.vimtex_compiler_latexmk = {
                out_dir = 'build',
                continuous = 1,
                callback = 1,
            }

            vim.api.nvim_create_autocmd("FileType", {
                pattern = "tex",
                callback = function()
                    vim.opt_local.spell = true
                    vim.opt_local.spelllang = "en_us" -- или "en_gb" для британского
                end,
            })
        end
    }
}
