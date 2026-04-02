local M       = {}
local uv      = vim.uv or vim.loop
local utils   = require("custom.import-rename.utils")
local py      = require("custom.import-rename.python")
local go      = require("custom.import-rename.go")
local neotree = require("custom.import-rename.neotree")

-- ─── helpers ───────────────────────────────────────────────

local function save_buf(bufnr)
    if bufnr ~= -1 and vim.bo[bufnr].modified then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    end
end

local function do_fs_rename(old, new)
    local parent = vim.fn.fnamemodify(new, ":h")
    if vim.fn.isdirectory(parent) == 0 then
        vim.fn.mkdir(parent, "p")
    end
    return uv.fs_rename(old, new)
end

-- ─── gitsigns ──────────────────────────────────────────────

local function refresh_gitsigns()
    vim.schedule(function()
        local ok, gs = pcall(require, "gitsigns")
        if not ok then return end
        pcall(gs.refresh)
    end)
end

-- ─── quickfix: построчный diff ─────────────────────────────

--- Сравнивает original и modified построчно.
--- Возвращает список qf-записей с номером строки и текстом вида:
---   file.go|5 col 1| - "old/path" → + "new/path"
--- При клике в :copen — курсор прыгнет на строку 5 в file.go,
--- а gitsigns подсветит hunk в sign column.
local function compute_line_diffs(filepath, original, modified)
    local old_lines = vim.split(original, "\n", { plain = true })
    local new_lines = vim.split(modified, "\n", { plain = true })
    local entries = {}
    local n = math.max(#old_lines, #new_lines)

    for i = 1, n do
        local ol = old_lines[i]
        local nl = new_lines[i]
        if ol ~= nl then
            local old_text = ol and vim.trim(ol) or "<removed>"
            local new_text = nl and vim.trim(nl) or "<added>"
            entries[#entries + 1] = {
                filename = filepath,
                lnum     = i,
                col      = 1,
                text     = string.format("- %s → + %s", old_text, new_text),
            }
        end
    end

    return entries
end

local function set_quickfix(entries, title)
    if #entries == 0 then return end
    vim.fn.setqflist(entries, "r")
    vim.fn.setqflist({}, "a", { title = title or "Import Rename" })
end

-- ─── undo ──────────────────────────────────────────────────

local function do_undo()
    local backup = utils.get_backup()
    if not backup then
        vim.notify("import-rename: nothing to undo", vim.log.levels.WARN)
        return
    end

    local fs = backup.fs_rename
    if fs then
        if not utils.target_exists(fs.new) then
            vim.notify("import-rename undo: source gone: " .. fs.new, vim.log.levels.ERROR)
            return
        end
        if utils.target_exists(fs.old) then
            vim.notify("import-rename undo: path occupied: " .. fs.old, vim.log.levels.ERROR)
            return
        end
        local ok, err = do_fs_rename(fs.new, fs.old)
        if not ok then
            vim.notify("import-rename undo: rename failed: " .. (err or "?"), vim.log.levels.ERROR)
            return
        end
        if backup.buf_renames then
            for _, br in ipairs(backup.buf_renames) do
                local bufnr = vim.fn.bufnr(br.new)
                if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
                    vim.api.nvim_buf_set_name(bufnr, br.old)
                    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! edit!") end)
                end
            end
        end
    end

    local restored = 0
    for filepath, content in pairs(backup.changes) do
        local write_path = filepath
        if fs then
            local np = fs.new .. "/"
            if filepath:sub(1, #np) == np then
                write_path = fs.old .. "/" .. filepath:sub(#np + 1)
            elseif filepath == fs.new then
                write_path = fs.old
            end
        end
        utils.write_file(write_path, content)
        utils.reload_buffer(write_path)
        restored = restored + 1
    end

    local age = os.time() - (backup.timestamp or 0)
    utils.clear_backup()
    refresh_gitsigns()

    -- очищаем quickfix
    vim.fn.setqflist({}, "r")

    vim.notify(
        string.format("import-rename: undo complete — %d files restored (%ds ago)",
            restored, age),
        vim.log.levels.INFO)

    pcall(function()
        require("neo-tree.sources.manager").refresh("filesystem")
    end)
end

-- ─── apply pending changes ─────────────────────────────────

--- Общая логика применения: пишет файлы, собирает backup, quickfix, gitsigns.
--- pending: список { filepath, original, modified }
--- fs_old, fs_new: пути для переименования на FS
--- buf: bufnr переименовываемого файла (или -1)
--- is_dir: true если переименовываем директорию
local function apply_changes(pending, fs_old, fs_new, buf, is_dir)
    local old_prefix     = is_dir and (fs_old .. "/") or nil
    local backup_changes = {}
    local qf_entries     = {}

    -- 1. записываем изменённые файлы
    for _, c in ipairs(pending) do
        backup_changes[c.filepath] = c.original
        utils.write_file(c.filepath, c.modified)
        utils.reload_buffer(c.filepath)
        vim.list_extend(qf_entries,
            compute_line_diffs(c.filepath, c.original, c.modified))
    end

    -- 2. переименование на FS
    local ok, err = do_fs_rename(fs_old, fs_new)
    if not ok then
        vim.notify("import-rename: rename failed: " .. (err or "?"), vim.log.levels.ERROR)
        for fp, content in pairs(backup_changes) do
            utils.write_file(fp, content)
            utils.reload_buffer(fp)
        end
        return false
    end

    -- 3. обновляем буферы
    local buf_renames = {}
    if is_dir then
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
                local name = vim.api.nvim_buf_get_name(b)
                if name:sub(1, #old_prefix) == old_prefix then
                    local new_name = fs_new .. "/" .. name:sub(#old_prefix + 1)
                    buf_renames[#buf_renames + 1] = { old = name, new = new_name }
                    vim.api.nvim_buf_set_name(b, new_name)
                    vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
                end
            end
        end
    elseif buf ~= -1 then
        buf_renames[1] = { old = fs_old, new = fs_new }
        vim.api.nvim_buf_set_name(buf, fs_new)
        vim.api.nvim_buf_call(buf, function() vim.cmd("silent! edit!") end)
    end

    -- 4. ремаппим пути backup/qf для файлов внутри переименованной директории
    if is_dir then
        local remapped = {}
        for fp, content in pairs(backup_changes) do
            if fp:sub(1, #old_prefix) == old_prefix then
                remapped[fs_new .. "/" .. fp:sub(#old_prefix + 1)] = content
            else
                remapped[fp] = content
            end
        end
        backup_changes = remapped

        for _, entry in ipairs(qf_entries) do
            local fn = entry.filename
            if fn:sub(1, #old_prefix) == old_prefix then
                entry.filename = fs_new .. "/" .. fn:sub(#old_prefix + 1)
            end
        end
    end

    -- 5. сохраняем backup
    utils.save_backup({
        changes     = backup_changes,
        fs_rename   = { old = fs_old, new = fs_new },
        buf_renames = buf_renames,
    })

    -- 6. quickfix + gitsigns
    local suffix = is_dir and "/" or ""
    local title = string.format("Import Rename: %s%s → %s%s",
        vim.fn.fnamemodify(fs_old, ":t"), suffix,
        vim.fn.fnamemodify(fs_new, ":t"), suffix)
    set_quickfix(qf_entries, title)
    refresh_gitsigns()

    return true
end

-- ─── confirm + notify ──────────────────────────────────────

local function confirm_and_apply(pending, fs_old, fs_new, buf, is_dir, callback)
    local function do_apply()
        local ok = apply_changes(pending, fs_old, fs_new, buf, is_dir)
        if ok then
            local suffix = is_dir and "/" or ""
            local hint = #pending > 0
                and " — :copen changes, ]c/[c hunks, <leader>ru undo"
                or ""
            vim.notify(
                string.format("import-rename: %s%s → %s%s (%d files, %d lines changed)%s",
                    vim.fn.fnamemodify(fs_old, ":~:."), suffix,
                    vim.fn.fnamemodify(fs_new, ":~:."), suffix,
                    #pending,
                    vim.fn.getqflist({ size = 0 }).size or 0,
                    hint),
                vim.log.levels.INFO)
        end
        if callback then callback(ok) end
        pcall(function()
            require("neo-tree.sources.manager").refresh("filesystem")
        end)
    end

    if #pending > 0 then
        local file_list = {}
        local seen = {}
        for _, c in ipairs(pending) do
            local short = vim.fn.fnamemodify(c.filepath, ":~:.")
            if not seen[short] then
                seen[short] = true
                file_list[#file_list + 1] = "  • " .. short
            end
        end
        local detail = table.concat(file_list, "\n")

        vim.ui.select({ "Yes", "No" }, {
            prompt = string.format(
                "import-rename: %d file(s) will be modified:\n%s\nProceed?",
                #file_list, detail),
        }, function(choice)
            if choice == "Yes" then
                vim.schedule(do_apply)
            else
                vim.notify("import-rename: cancelled", vim.log.levels.INFO)
            end
        end)
    else
        do_apply()
    end
end

-- ─── file rename ───────────────────────────────────────────

local function do_rename_file(old_path, new_path)
    if utils.target_exists(new_path) then
        vim.notify("import-rename: target already exists: "
            .. vim.fn.fnamemodify(new_path, ":~:."), vim.log.levels.ERROR)
        return
    end

    local root = utils.find_project_root(vim.fn.fnamemodify(old_path, ":h"))

    local is_py = old_path:match("%.py$") ~= nil
    local is_go = old_path:match("%.go$") ~= nil
    if not is_py and not is_go then
        vim.notify("import-rename: only .py and .go supported", vim.log.levels.WARN)
        return
    end

    local buf = vim.fn.bufnr(old_path)
    save_buf(buf)

    local pending = {}

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
                            pending[#pending + 1] = {
                                filepath = fp, original = content, modified = nc,
                            }
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
                        local nc, did = go.refactor_file(content, old_imp, new_imp)
                        if did then
                            pending[#pending + 1] = {
                                filepath = fp, original = content, modified = nc,
                            }
                        end
                    end
                end
            end
        end
    end

    confirm_and_apply(pending, old_path, new_path, buf, false)
end

-- ─── directory rename ──────────────────────────────────────

local function do_rename_dir(old_dir, new_dir)
    old_dir = old_dir:gsub("/+$", "")
    new_dir = new_dir:gsub("/+$", "")

    if utils.target_exists(new_dir) then
        vim.notify("import-rename: target already exists: "
            .. vim.fn.fnamemodify(new_dir, ":~:."), vim.log.levels.ERROR)
        return
    end

    local root       = utils.find_project_root(vim.fn.fnamemodify(old_dir, ":h"))
    local old_prefix = old_dir .. "/"

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = vim.api.nvim_buf_get_name(b)
            if name:sub(1, #old_prefix) == old_prefix then
                save_buf(vim.fn.bufnr(name))
            end
        end
    end

    local pending = {}

    -- Python
    local py_files = utils.collect_files(root, { ".py" })
    if #py_files > 0 then
        local old_mod = py.path_to_module(root, old_dir)
        local new_mod = py.path_to_module(root, new_dir)
        if old_mod ~= new_mod then
            for _, fp in ipairs(py_files) do
                local content = utils.read_file(fp)
                if content then
                    local pkg
                    if fp:sub(1, #old_prefix) == old_prefix then
                        local projected = new_dir .. "/" .. fp:sub(#old_prefix + 1)
                        pkg = py.get_package(root, projected)
                    else
                        pkg = py.get_package(root, fp)
                    end
                    local nc, did = py.replace_imports(content, old_mod, new_mod, pkg)
                    if did then
                        pending[#pending + 1] = {
                            filepath = fp, original = content, modified = nc,
                        }
                    end
                end
            end
        end
    end

    -- Go
    local go_files = utils.collect_files(root, { ".go" })
    if #go_files > 0 then
        local go_mod_name = go.get_module_name(root)
        if go_mod_name then
            local old_imp = go.dir_to_import(root, go_mod_name, old_dir)
            local new_imp = go.dir_to_import(root, go_mod_name, new_dir)
            if old_imp ~= new_imp then
                local old_dir_name = old_dir:match("([^/]+)$")
                local new_dir_name = new_dir:match("([^/]+)$")

                for _, fp in ipairs(go_files) do
                    local content = utils.read_file(fp)
                    if content then
                        local did_any  = false
                        local original = content

                        if fp:sub(1, #old_prefix) == old_prefix then
                            local rel = fp:sub(#old_prefix + 1)
                            if not rel:find("/") then
                                local nc, did = go.replace_package_decl(
                                    content, old_dir_name, new_dir_name)
                                if did then
                                    content = nc; did_any = true
                                end
                            end
                        end

                        local nc, did = go.refactor_file(content, old_imp, new_imp)
                        if did then
                            content = nc; did_any = true
                        end

                        if did_any then
                            pending[#pending + 1] = {
                                filepath = fp, original = original, modified = content,
                            }
                        end
                    end
                end
            end
        end
    end

    confirm_and_apply(pending, old_dir, new_dir, -1, true)
end

-- ─── setup ─────────────────────────────────────────────────

function M.setup()
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
                if not new_name or new_name == "" or new_name == old_name then
                    return
                end
                local new_path = utils.path_join(parent, new_name)
                if node_type == "directory" then
                    do_rename_dir(path, new_path)
                else
                    do_rename_file(path, new_path)
                end
            end)
        end)
    end, { desc = "Rename file/dir + update imports" })

    vim.api.nvim_create_user_command("ImportRenameUndo", function()
        do_undo()
    end, { desc = "Undo last import-rename operation" })

    vim.api.nvim_create_autocmd("FileType", {
        pattern = "neo-tree",
        callback = function(ev)
            vim.keymap.set("n", "<leader>rr", "<cmd>ImportRename<cr>",
                { buffer = ev.buf, desc = "Rename + update imports" })
        end,
    })

    vim.keymap.set("n", "<leader>ru", "<cmd>ImportRenameUndo<cr>",
        { desc = "Undo last import-rename" })
end

return M
