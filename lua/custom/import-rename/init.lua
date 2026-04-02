local M = {}
local uv = vim.uv or vim.loop

-- ============================================================
-- Utilities
-- ============================================================

local function path_join(...)
    return table.concat({ ... }, "/"):gsub("//+", "/")
end

local function find_project_root(start_path)
    local markers = { "pyproject.toml", "setup.py", "setup.cfg", "go.mod", ".git" }
    local path = start_path
    while path and path ~= "/" do
        for _, m in ipairs(markers) do
            local c = path_join(path, m)
            if vim.fn.filereadable(c) == 1 or vim.fn.isdirectory(c) == 1 then
                return path
            end
        end
        local parent = vim.fn.fnamemodify(path, ":h")
        if parent == path then break end
        path = parent
    end
    return vim.fn.getcwd()
end

local function collect_files(dir, extensions)
    local results = {}
    local skip = {
        "__pycache__", ".git", ".venv", "venv", "env",
        "node_modules", "vendor", "build", "dist",
    }
    local function scan(d)
        local handle = uv.fs_scandir(d)
        if not handle then return end
        while true do
            local name, ftype = uv.fs_scandir_next(handle)
            if not name then break end
            local full = path_join(d, name)
            if not ftype then
                local stat = uv.fs_stat(full)
                ftype = stat and stat.type
            end
            if ftype == "directory" then
                local dominated = false
                for _, s in ipairs(skip) do
                    if name == s then
                        dominated = true; break
                    end
                end
                if not dominated and name:sub(1, 1) ~= "." then scan(full) end
            elseif ftype == "file" then
                for _, ext in ipairs(extensions) do
                    if name:sub(- #ext) == ext then
                        table.insert(results, full)
                        break
                    end
                end
            end
        end
    end
    scan(dir)
    return results
end

local function read_file(filepath)
    local fd = uv.fs_open(filepath, "r", 438)
    if not fd then return nil end
    local stat = uv.fs_fstat(fd)
    if not stat then
        uv.fs_close(fd); return nil
    end
    local data = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    return data
end

local function write_file(filepath, data)
    local fd = uv.fs_open(filepath, "w", 438)
    if not fd then return false end
    uv.fs_write(fd, data)
    uv.fs_close(fd)
    return true
end

local function reload_buffer(filepath)
    local bufnr = vim.fn.bufnr(filepath)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            if not vim.bo[bufnr].modified then
                vim.cmd("silent! edit!")
            end
        end)
    end
end

-- ============================================================
-- Python
-- ============================================================

local function py_path_to_module(root, filepath)
    local rel = filepath:sub(#root + 2)
    rel = rel:gsub("%.py$", "")
    rel = rel:gsub("/__init__$", "")
    rel = rel:gsub("/", ".")
    return rel
end

--- Проверяет, является ли text модулем old_mod или его подмодулем.
--- Если да — заменяет префикс на new_mod.
local function replace_module_ref(text, old_mod, new_mod)
    if text == old_mod then
        return new_mod, true
    end
    local prefix = old_mod .. "."
    if text:sub(1, #prefix) == prefix then
        return new_mod .. text:sub(#old_mod + 1), true
    end
    return text, false
end

local function py_replace_imports(content, old_mod, new_mod)
    local changed = false
    local lines = vim.split(content, "\n", { plain = true })
    local result = {}

    -- Для случая "from parent import leaf"
    local old_parts = vim.split(old_mod, ".", { plain = true })
    local new_parts = vim.split(new_mod, ".", { plain = true })
    local old_leaf = old_parts[#old_parts]
    local new_leaf = new_parts[#new_parts]
    local old_parent = #old_parts > 1
        and table.concat(old_parts, ".", 1, #old_parts - 1)
        or nil
    local new_parent = #new_parts > 1
        and table.concat(new_parts, ".", 1, #new_parts - 1)
        or nil

    for _, line in ipairs(lines) do
        local new_line = line

        -- Пробуем "from MODULE import ..."
        local from_pre, from_mod, from_rest =
            line:match("^(%s*from%s+)([%w_%.]+)(%s+import.*)$")

        if from_pre then
            -- Случай 1: from old_mod[.sub] import X
            local replaced, did = replace_module_ref(from_mod, old_mod, new_mod)
            if did then
                new_line = from_pre .. replaced .. from_rest
                changed = true

                -- Случай 2: from parent import old_leaf
            elseif old_parent and from_mod == old_parent then
                local kw, import_list = from_rest:match("^(%s+import%s+)(.*)$")
                if kw and import_list then
                    local new_from = old_parent
                    local new_list = import_list
                    local need = false

                    if new_parent and old_parent ~= new_parent then
                        new_from = new_parent
                        need = true
                    end
                    if old_leaf ~= new_leaf then
                        local rl = import_list:gsub(
                            "(%f[%w_])" .. vim.pesc(old_leaf) .. "(%f[^%w_])",
                            "%1" .. new_leaf .. "%2"
                        )
                        if rl ~= import_list then
                            new_list = rl
                            need = true
                        end
                    end
                    if need then
                        new_line = from_pre .. new_from .. kw .. new_list
                        changed = true
                    end
                end
            end
        else
            -- Пробуем standalone "import MODULE[, MODULE, ...]"
            local imp_pre, imp_list = line:match("^(%s*import%s+)(.+)$")
            if imp_pre then
                local modules = vim.split(imp_list, ",", { plain = true })
                local any = false

                for i, m in ipairs(modules) do
                    local trimmed = vim.trim(m)
                    local mod_name, alias =
                        trimmed:match("^([%w_%.]+)(%s+as%s+[%w_]+)$")
                    if not mod_name then
                        mod_name = trimmed:match("^([%w_%.]+)$")
                        alias = ""
                    end
                    if mod_name then
                        local replaced, did = replace_module_ref(mod_name, old_mod, new_mod)
                        if did then
                            local leading = m:match("^(%s*)") or ""
                            modules[i] = leading .. replaced .. (alias or "")
                            any = true
                        end
                    end
                end

                if any then
                    new_line = imp_pre .. table.concat(modules, ",")
                    changed = true
                end
            end
        end

        table.insert(result, new_line)
    end

    if changed then
        return table.concat(result, "\n"), true
    end
    return content, false
end

-- ============================================================
-- Go
-- ============================================================

local function go_get_module_name(root)
    local content = read_file(path_join(root, "go.mod"))
    if not content then return nil end
    return content:match("module%s+([%w%._%-/]+)")
end

local function go_dir_to_import(root, go_module, dirpath)
    local rel = dirpath:sub(#root + 2)
    if not rel or rel == "" then return go_module end
    return go_module .. "/" .. rel
end

local function go_replace_imports(content, old_imp, new_imp)
    local changed = false
    local new_content = content:gsub('"([^"\n]+)"', function(path)
        if path == old_imp then
            changed = true
            return '"' .. new_imp .. '"'
        end
        local prefix = old_imp .. "/"
        if path:sub(1, #prefix) == prefix then
            changed = true
            return '"' .. new_imp .. path:sub(#old_imp + 1) .. '"'
        end
        return '"' .. path .. '"'
    end)
    return new_content, changed
end

-- ============================================================
-- Core
-- ============================================================

local function do_file_rename(old_path, new_path)
    local root = find_project_root(vim.fn.fnamemodify(old_path, ":h"))

    local is_py = old_path:match("%.py$") ~= nil
    local is_go = old_path:match("%.go$") ~= nil
    if not is_py and not is_go then
        vim.notify("import-rename: only .py and .go supported", vim.log.levels.WARN)
        return
    end

    -- Сохраняем буфер, пока файл ещё на старом месте
    local cur_buf = vim.fn.bufnr(old_path)
    if cur_buf ~= -1 and vim.bo[cur_buf].modified then
        vim.api.nvim_buf_call(cur_buf, function()
            vim.cmd("silent! write")
        end)
    end

    local total = 0

    if is_py then
        local old_mod = py_path_to_module(root, old_path)
        local new_mod = py_path_to_module(root, new_path)
        if old_mod ~= new_mod then
            for _, fp in ipairs(collect_files(root, { ".py" })) do
                if fp ~= old_path and fp ~= new_path then
                    local content = read_file(fp)
                    if content then
                        local nc, did = py_replace_imports(content, old_mod, new_mod)
                        if did then
                            write_file(fp, nc)
                            total = total + 1
                            reload_buffer(fp)
                        end
                    end
                end
            end
        end
    elseif is_go then
        local go_mod = go_get_module_name(root)
        if not go_mod then
            vim.notify("import-rename: go.mod not found", vim.log.levels.ERROR)
            return
        end
        local old_imp = go_dir_to_import(root, go_mod, vim.fn.fnamemodify(old_path, ":h"))
        local new_imp = go_dir_to_import(root, go_mod, vim.fn.fnamemodify(new_path, ":h"))
        if old_imp ~= new_imp then
            for _, fp in ipairs(collect_files(root, { ".go" })) do
                if fp ~= old_path and fp ~= new_path then
                    local content = read_file(fp)
                    if content then
                        local nc, did = go_replace_imports(content, old_imp, new_imp)
                        if did then
                            write_file(fp, nc)
                            total = total + 1
                            reload_buffer(fp)
                        end
                    end
                end
            end
        end
    end

    -- Переименовываем файл на диске
    local new_parent = vim.fn.fnamemodify(new_path, ":h")
    if vim.fn.isdirectory(new_parent) == 0 then
        vim.fn.mkdir(new_parent, "p")
    end
    local ok, err = uv.fs_rename(old_path, new_path)
    if not ok then
        vim.notify("import-rename: rename failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
    end

    -- Обновляем буфер
    if cur_buf ~= -1 then
        vim.api.nvim_buf_set_name(cur_buf, new_path)
        vim.api.nvim_buf_call(cur_buf, function()
            vim.cmd("silent! edit!")
        end)
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

-- ============================================================
-- Commands
-- ============================================================

function M.setup()
    vim.api.nvim_create_user_command("ImportRename", function(opts)
        local old_path = vim.fn.expand("%:p")
        if vim.fn.filereadable(old_path) == 0 then
            vim.notify("import-rename: not a file on disk", vim.log.levels.ERROR)
            return
        end

        local function run(name)
            if not name or name == "" then return end
            local new_path = path_join(vim.fn.fnamemodify(old_path, ":h"), name)
            if new_path == old_path then return end
            do_file_rename(old_path, new_path)
        end

        if opts.args ~= "" then
            run(opts.args)
        else
            vim.ui.input({
                prompt = "New file name: ",
                default = vim.fn.expand("%:t"),
            }, function(input)
                vim.schedule(function() run(input) end)
            end)
        end
    end, { nargs = "?", desc = "Rename file and update imports" })

    vim.api.nvim_create_user_command("ImportMove", function(opts)
        local old_path = vim.fn.expand("%:p")
        if vim.fn.filereadable(old_path) == 0 then
            vim.notify("import-rename: not a file on disk", vim.log.levels.ERROR)
            return
        end

        local function resolve(input)
            if not input or input == "" then return nil end
            if input:sub(1, 1) == "/" then return input end
            if input:sub(1, 2) == "~/" then return vim.fn.expand(input) end
            return path_join(vim.fn.getcwd(), input)
        end

        local function run(input)
            local new_path = resolve(input)
            if not new_path or new_path == old_path then return end
            do_file_rename(old_path, new_path)
        end

        if opts.args ~= "" then
            run(opts.args)
        else
            vim.ui.input({
                prompt = "Move to: ",
                default = vim.fn.fnamemodify(old_path, ":~:."),
                completion = "file",
            }, function(input)
                vim.schedule(function() run(input) end)
            end)
        end
    end, { nargs = "?", desc = "Move file and update imports", complete = "file" })
end

return M
