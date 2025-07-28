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
        end
    }
}
