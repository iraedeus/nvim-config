return {
    {
        'neovim/nvim-lspconfig',
        config = function()
            local lspconfig = require('lspconfig')

            local on_attach = function(client, bufnr)
                local opts = { buffer = bufnr, remap = false }

                vim.keymap.set("n", "<leader>rn", "<cmd>Lspsaga rename<CR>", opts)

                vim.keymap.set("n", "K", "<cmd>Lspsaga hover_doc<CR>", opts)
                vim.keymap.set("n", "gr", "<cmd>Lspsaga finder<CR>", opts)
            end

            vim.diagnostic.config({
                virtual_text = true
            })

            lspconfig.lua_ls.setup({
                on_attach = on_attach,
                settings = {
                    Lua = {
                        diagnostics = {
                            globals = { 'vim' }
                        }
                    }
                }
            })

            lspconfig.pyright.setup({
                on_attach = on_attach,
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
