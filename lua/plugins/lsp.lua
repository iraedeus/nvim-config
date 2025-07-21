return {
    {
        'neovim/nvim-lspconfig',
        config = function()
            local lspconfig = require('lspconfig')
            vim.diagnostic.config({
                virtual_text = true
            })

            lspconfig.lua_ls.setup({
                settings = {
                    Lua = {
                        diagnostics = {
                            globals = { 'vim' }
                        }
                    }
                }
            })

            lspconfig.pyright.setup({
                settings = {
                    python = {
                        analysis = {
                            diagnosticMode = "workspace",
                        }
                    }
                }
            })
        end,
    },
}
