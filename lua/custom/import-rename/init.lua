local M       = {}
local uv      = vim.uv or vim.loop
local utils   = require("custom.import-rename.utils")
local py      = require("custom.import-rename.python")
local go      = require("custom.import-rename.go")
local neotree = require("custom.import-rename.neotree")

local function do_rename_and_update(old_path, new_path)
    local root = utils.find_project_root(vim.fn.fnamemodify(old_path, ":h"))

    local is_py = old_path:match("%.py$") ~= nil
    local is_go = old_path:match("%.go$") ~= nil
    if not is_py and not is_go then
        vim.notify("import-rename: only .py and .go supported", vim.log.levels.WARN)
        return
    end

    local buf = vim.fn.bufnr(old_path)
    if buf ~= -1 and vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end)
    end

    local total = 0

    if is_py then
        local old_mod = py.path_to_module(root, old_path)
        local new_mod = py.path_to_module(root, new_path)
        if old_mod ~= new_mod then
            for _, fp in ipairs(utils.collect_files(root, { ".py" })) do
                if fp ~= old_path and fp ~= new_path then
                    local content = utils.read_file(fp)
                    if content then
                        local pkg = py.get_package(root, fp)
                        local nc, did = py.replace_imports(content, old_mod, new_mod, pkg)
                        if did then
                            utils.write_file(fp, nc)
                            total = total + 1
                            utils.reload_buffer(fp)
                        end
                    end
                end
            end
        end
    elseif is_go then
        local go_mod = go.get_module_name(root)
        if not go_mod then
            vim.notify("import-rename: go.mod not found", vim.log.levels.ERROR)
            return
        end
        local old_imp = go.dir_to_import(root, go_mod, vim.fn.fnamemodify(old_path, ":h"))
        local new_imp = go.dir_to_import(root, go_mod, vim.fn.fnamemodify(new_path, ":h"))
        if old_imp ~= new_imp then
            for _, fp in ipairs(utils.collect_files(root, { ".go" })) do
                if fp ~= old_path and fp ~= new_path then
                    local content = utils.read_file(fp)
                    if content then
                        local nc, did = go.replace_imports(content, old_imp, new_imp)
                        if did then
                            utils.write_file(fp, nc)
                            total = total + 1
                            utils.reload_buffer(fp)
                        end
                    end
                end
            end
        end
    end

    -- Rename the file itself
    local new_parent = vim.fn.fnamemodify(new_path, ":h")
    if vim.fn.isdirectory(new_parent) == 0 then
        vim.fn.mkdir(new_parent, "p")
    end
    local ok, err = uv.fs_rename(old_path, new_path)
    if not ok then
        vim.notify("import-rename: rename failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
    end

    if buf ~= -1 then
        vim.api.nvim_buf_set_name(buf, new_path)
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent! edit!") end)
    end

    vim.notify(
        string.format(
            "import-rename: %s → %s (%d files updated)",
            vim.fn.fnamemodify(old_path, ":~:."),
            vim.fn.fnamemodify(new_path, ":~:."),
            total
        ),
        vim.log.levels.INFO
    )
end

function M.setup()
    vim.api.nvim_create_user_command("ImportRename", function()
        local filepath, err = neotree.get_file_path()
        if not filepath then
            vim.notify("import-rename: " .. (err or "unknown error"), vim.log.levels.ERROR)
            return
        end

        local old_name = vim.fn.fnamemodify(filepath, ":t")
        local dir = vim.fn.fnamemodify(filepath, ":h")

        vim.ui.input({
            prompt = "Rename to: ",
            default = old_name,
        }, function(new_name)
            vim.schedule(function()
                if not new_name or new_name == "" or new_name == old_name then
                    return
                end
                local new_path = utils.path_join(dir, new_name)
                do_rename_and_update(filepath, new_path)
                pcall(function()
                    require("neo-tree.command").execute({ action = "refresh" })
                end)
            end)
        end)
    end, { desc = "Rename file + update imports" })

    vim.api.nvim_create_autocmd("FileType", {
        pattern = "neo-tree",
        callback = function(ev)
            vim.keymap.set("n", "<leader>rr", "<cmd>ImportRename<cr>",
                { buffer = ev.buf, desc = "Rename file + update imports" })
        end,
    })
end

return M
