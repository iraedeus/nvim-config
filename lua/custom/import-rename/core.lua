local M             = {}
local uv            = vim.uv or vim.loop
local utils         = require("custom.import-rename.utils")

-- Языковые хендлеры: каждый реализует collect_pending(root, old, new, is_dir)
local handlers      = {
    require("custom.import-rename.go"),
    require("custom.import-rename.python"),
}

local supported_ext = { [".py"] = true, [".go"] = true }

-- ─── helpers ───────────────────────────────────────────────

local function save_buf(bufnr)
    if bufnr ~= -1 and vim.bo[bufnr].modified then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    end
end

local function fs_rename(old, new)
    local parent = vim.fn.fnamemodify(new, ":h")
    if vim.fn.isdirectory(parent) == 0 then vim.fn.mkdir(parent, "p") end
    return uv.fs_rename(old, new)
end

local function refresh_gitsigns()
    vim.schedule(function()
        local ok, gs = pcall(require, "gitsigns")
        if ok then pcall(gs.refresh) end
    end)
end

local function refresh_neotree()
    pcall(function() require("neo-tree.sources.manager").refresh("filesystem") end)
end

local function remap_path(fp, old_prefix, new_base)
    if fp:sub(1, #old_prefix) == old_prefix then
        return new_base .. "/" .. fp:sub(#old_prefix + 1)
    end
    return fp
end

-- ─── quickfix ──────────────────────────────────────────────

local function compute_line_diffs(filepath, original, modified)
    local old_lines = vim.split(original, "\n", { plain = true })
    local new_lines = vim.split(modified, "\n", { plain = true })
    local entries   = {}
    for i = 1, math.max(#old_lines, #new_lines) do
        if old_lines[i] ~= new_lines[i] then
            entries[#entries + 1] = {
                filename = filepath,
                lnum     = i,
                col      = 1,
                text     = string.format("- %s → + %s",
                    old_lines[i] and vim.trim(old_lines[i]) or "<removed>",
                    new_lines[i] and vim.trim(new_lines[i]) or "<added>"),
            }
        end
    end
    return entries
end

-- ─── apply ─────────────────────────────────────────────────

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
    local ok, err = fs_rename(fs_old, fs_new)
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

    -- 4. ремаппим пути для файлов внутри переименованной директории
    if is_dir then
        local remapped = {}
        for fp, content in pairs(backup_changes) do
            remapped[remap_path(fp, old_prefix, fs_new)] = content
        end
        backup_changes = remapped

        for _, entry in ipairs(qf_entries) do
            entry.filename = remap_path(entry.filename, old_prefix, fs_new)
        end
    end

    -- 5. backup
    utils.save_backup({
        changes     = backup_changes,
        fs_rename   = { old = fs_old, new = fs_new },
        buf_renames = buf_renames,
    })

    -- 6. quickfix + gitsigns
    if #qf_entries > 0 then
        local sfx = is_dir and "/" or ""
        vim.fn.setqflist(qf_entries, "r")
        vim.fn.setqflist({}, "a", {
            title = string.format("Import Rename: %s%s → %s%s",
                vim.fn.fnamemodify(fs_old, ":t"), sfx,
                vim.fn.fnamemodify(fs_new, ":t"), sfx),
        })
    end
    refresh_gitsigns()

    return true
end

-- ─── confirm ───────────────────────────────────────────────

local function confirm_and_apply(pending, fs_old, fs_new, buf, is_dir)
    local function do_apply()
        if apply_changes(pending, fs_old, fs_new, buf, is_dir) then
            local sfx  = is_dir and "/" or ""
            local hint = #pending > 0
                and " — :copen changes, ]c/[c hunks, <leader>ru undo" or ""
            vim.notify(string.format(
                "import-rename: %s%s → %s%s (%d files, %d lines changed)%s",
                vim.fn.fnamemodify(fs_old, ":~:."), sfx,
                vim.fn.fnamemodify(fs_new, ":~:."), sfx,
                #pending,
                vim.fn.getqflist({ size = 0 }).size or 0,
                hint), vim.log.levels.INFO)
        end
        refresh_neotree()
    end

    if #pending == 0 then
        do_apply(); return
    end

    local seen, file_list = {}, {}
    for _, c in ipairs(pending) do
        local short = vim.fn.fnamemodify(c.filepath, ":~:.")
        if not seen[short] then
            seen[short] = true
            file_list[#file_list + 1] = "  • " .. short
        end
    end

    vim.ui.select({ "Yes", "No" }, {
        prompt = string.format("import-rename: %d file(s) will be modified:\n%s\nProceed?",
            #file_list, table.concat(file_list, "\n")),
    }, function(choice)
        if choice == "Yes" then
            vim.schedule(do_apply)
        else
            vim.notify("import-rename: cancelled", vim.log.levels.INFO)
        end
    end)
end

-- ─── undo ──────────────────────────────────────────────────

function M.undo()
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
        local ok, err = fs_rename(fs.new, fs.old)
        if not ok then
            vim.notify("import-rename undo: rename failed: " .. (err or "?"), vim.log.levels.ERROR)
            return
        end
        for _, br in ipairs(backup.buf_renames or {}) do
            local bufnr = vim.fn.bufnr(br.new)
            if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
                vim.api.nvim_buf_set_name(bufnr, br.old)
                vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! edit!") end)
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
    vim.fn.setqflist({}, "r")

    vim.notify(string.format(
        "import-rename: undo complete — %d files restored (%ds ago)",
        restored, age), vim.log.levels.INFO)
    refresh_neotree()
end

-- ─── rename (unified file + dir) ──────────────────────────

function M.rename(old_path, new_path, is_dir)
    if is_dir then
        old_path = old_path:gsub("/+$", "")
        new_path = new_path:gsub("/+$", "")
    end

    if utils.target_exists(new_path) then
        vim.notify("import-rename: target already exists: "
            .. vim.fn.fnamemodify(new_path, ":~:."), vim.log.levels.ERROR)
        return
    end

    if not is_dir and not supported_ext[old_path:match("%.%w+$") or ""] then
        vim.notify("import-rename: only .py and .go supported", vim.log.levels.WARN)
        return
    end

    local root = utils.find_project_root(vim.fn.fnamemodify(old_path, ":h"))

    -- сохраняем модифицированные буферы
    if is_dir then
        local prefix = old_path .. "/"
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b)
                and vim.api.nvim_buf_get_name(b):sub(1, #prefix) == prefix then
                save_buf(b)
            end
        end
    else
        save_buf(vim.fn.bufnr(old_path))
    end

    -- собираем pending со всех языковых хендлеров
    local pending = {}
    for _, handler in ipairs(handlers) do
        vim.list_extend(pending, handler.collect_pending(root, old_path, new_path, is_dir))
    end

    local buf = not is_dir and vim.fn.bufnr(old_path) or -1
    confirm_and_apply(pending, old_path, new_path, buf, is_dir)
end

return M
