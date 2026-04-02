local M = {}

function M.setup()
    local core    = require("custom.import-rename.core")
    local neotree = require("custom.import-rename.neotree")
    local utils   = require("custom.import-rename.utils")

    vim.api.nvim_create_user_command("ImportRename", function()
        local path, node_type, err = neotree.get_node_info()
        if not path then
            vim.notify("import-rename: " .. (err or "unknown error"), vim.log.levels.ERROR)
            return
        end

        local old_name = vim.fn.fnamemodify(path, ":t")
        local parent   = vim.fn.fnamemodify(path, ":h")

        vim.ui.input({
            prompt  = "Rename to: ",
            default = old_name,
        }, function(new_name)
            vim.schedule(function()
                if not new_name or new_name == "" or new_name == old_name then return end
                core.rename(path, utils.path_join(parent, new_name), node_type == "directory")
            end)
        end)
    end, { desc = "Rename file/dir + update imports" })

    vim.api.nvim_create_user_command("ImportRenameUndo", function()
        core.undo()
    end, { desc = "Undo last import-rename operation" })

    vim.api.nvim_create_autocmd("FileType", {
        pattern  = "neo-tree",
        callback = function(ev)
            vim.keymap.set("n", "<leader>rr", "<cmd>ImportRename<cr>",
                { buffer = ev.buf, desc = "Rename + update imports" })
        end,
    })

    vim.keymap.set("n", "<leader>ru", "<cmd>ImportRenameUndo<cr>",
        { desc = "Undo last import-rename" })
end

return M
