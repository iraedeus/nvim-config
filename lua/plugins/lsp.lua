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

            lspconfig.clangd.setup({})

            lspconfig.texlab.setup({})

            -- ######
            -- PYTHON
            -- ######

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

            -- ######
            -- GOLANG
            -- ######

            lspconfig.gopls.setup({
                on_attach = on_attach,
                settings = {
                    gopls = {
                        analyses = {
                            unusedparams = true,
                        },
                        staticcheck = true,
                        gofumpt = true,
                    },
                },
            })

            vim.api.nvim_create_autocmd("BufWritePre", {
                pattern = "*.go",
                callback = function()
                    local params = vim.lsp.util.make_range_params()
                    params.context = { only = { "source.organizeImports" } }
                    local result = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, 1000)
                    for cid, res in pairs(result or {}) do
                        for _, r in pairs(res.result or {}) do
                            if r.edit then
                                local enc = (vim.lsp.get_client_by_id(cid) or {}).offset_encoding or "utf-16"
                                vim.lsp.util.apply_workspace_edit(r.edit, enc)
                            end
                        end
                    end
                    vim.lsp.buf.format({ async = false })
                end
            })
        end,
    },
}
