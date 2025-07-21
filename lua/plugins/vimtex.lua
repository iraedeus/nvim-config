return {
    {
        "lervag/vimtex",
        ft = "tex",
        config = function()
            vim.g.vimtex_view_method = "zathura"
            vim.g.vimtex_view_automatic = 1
            vim.g.vimtex_compiler_latexmk = {
                engine = 'lualatex',
                out_dir = 'build',
                continuous = 1,
                shell_escape = 1,
                background = 1,
                options = {
                    '-pdf',
                    '-interaction=nonstopmode',
                    '-synctex=1',
                },
            }
        end
    }
}
