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
-- Neo-tree: получить путь файла под курсором
-- ============================================================

local function get_neotree_file_path()
    if vim.bo.filetype ~= "neo-tree" then
        return nil, "Not in neo-tree"
    end

    local ok, manager = pcall(require, "neo-tree.sources.manager")
    if not ok then return nil, "neo-tree not loaded" end

    local state = manager.get_state("filesystem")
    if not state or not state.tree then return nil, "no tree state" end

    local node = state.tree:get_node()
    if not node then return nil, "no node under cursor" end

    if node.type ~= "file" then
        return nil, "Cursor is not on a file"
    end

    return node.path, nil
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

--- Определяет пакет файла.
--- Для __init__.py пакет = сам модуль (он и есть пакет).
--- Для обычного файла пакет = родительский модуль.
local function py_get_package(root, filepath)
    local is_init = filepath:match("/__init__%.py$") ~= nil
    local mod = py_path_to_module(root, filepath)
    if is_init then
        return mod
    end
    local parts = vim.split(mod, ".", { plain = true })
    if #parts <= 1 then
        return nil -- top-level модуль, пакета нет
    end
    return table.concat(parts, ".", 1, #parts - 1)
end

--- Резолвит относительный импорт в абсолютный.
--- source_package — пакет файла (не модуль!)
--- dots — кол-во точек: 1=".", 2="..", ...
--- В Python: . = текущий пакет (0 уровней вверх), .. = 1 вверх, ...
local function py_resolve_relative(source_package, dots, rel_mod)
    if not source_package then return nil end
    local parts = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then
        return nil
    end
    local n = #parts - levels_up
    local base_parts = {}
    for i = 1, n do
        base_parts[i] = parts[i]
    end
    local base = table.concat(base_parts, ".")
    if rel_mod and rel_mod ~= "" then
        return base .. "." .. rel_mod
    end
    return base
end

--- Обратная операция: абсолютный модуль → относительный с dots точками.
local function py_make_relative(source_package, abs_mod, dots)
    if not source_package then return nil, nil end
    local parts = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then
        return nil, nil
    end
    local n = #parts - levels_up
    local base_parts = {}
    for i = 1, n do
        base_parts[i] = parts[i]
    end
    local base = table.concat(base_parts, ".")
    local dots_str = string.rep(".", dots)

    if abs_mod == base then
        return dots_str, ""
    end

    local prefix = base .. "."
    if abs_mod:sub(1, #prefix) == prefix then
        return dots_str, abs_mod:sub(#prefix + 1)
    end

    return nil, nil
end

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

local function py_replace_imports(content, old_mod, new_mod, source_package)
    local changed = false
    local lines = vim.split(content, "\n", { plain = true })
    local result = {}

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

        -- =======================================================
        -- Относительные импорты: from .xxx import ... / from .. import ...
        -- =======================================================
        local rel_pre, rel_dots, rel_mod_part, rel_rest =
            line:match("^(%s*from%s+)(%.+)([%w_%.]*)([ \t]+import.*)$")

        if rel_pre and source_package then
            local ndots = #rel_dots
            local abs_from = py_resolve_relative(source_package, ndots, rel_mod_part)
            if abs_from then
                local replaced_from, did_from = replace_module_ref(abs_from, old_mod, new_mod)
                if did_from then
                    -- Пробуем сохранить относительность с тем же кол-вом точек
                    local new_dots_str, new_rel = py_make_relative(source_package, replaced_from, ndots)
                    if new_dots_str then
                        new_line = rel_pre .. new_dots_str .. new_rel .. rel_rest
                    else
                        -- Не получилось — пишем абсолютный
                        new_line = rel_pre .. replaced_from .. rel_rest
                    end
                    changed = true
                elseif old_parent and abs_from == old_parent then
                    -- from .parent import leaf
                    local kw, import_list = rel_rest:match("^([ \t]+import%s+)(.*)$")
                    if kw and import_list then
                        local new_from_abs = old_parent
                        local new_list = import_list
                        local need = false

                        if new_parent and old_parent ~= new_parent then
                            new_from_abs = new_parent
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
                            local new_dots_str, new_rel = py_make_relative(source_package, new_from_abs, ndots)
                            if new_dots_str then
                                new_line = rel_pre .. new_dots_str .. new_rel .. kw .. new_list
                            else
                                new_line = rel_pre .. new_from_abs .. kw .. new_list
                            end
                            changed = true
                        end
                    end
                end
            end
        else
            -- =======================================================
            -- Абсолютные импорты
            -- =======================================================
            local from_pre, from_mod, from_rest =
                line:match("^(%s*from%s+)([%w_%.]+)(%s+import.*)$")

            if from_pre then
                local replaced, did = replace_module_ref(from_mod, old_mod, new_mod)
                if did then
                    new_line = from_pre .. replaced .. from_rest
                    changed = true
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
-- Core: переименование + обновление импортов
-- ============================================================

local function do_rename_and_update(old_path, new_path)
    local root = find_project_root(vim.fn.fnamemodify(old_path, ":h"))

    local is_py = old_path:match("%.py$") ~= nil
    local is_go = old_path:match("%.go$") ~= nil
    if not is_py and not is_go then
        vim.notify("import-rename: only .py and .go supported", vim.log.levels.WARN)
        return
    end

    local buf = vim.fn.bufnr(old_path)
    if buf ~= -1 and vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function()
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
                        local source_package = py_get_package(root, fp)
                        local nc, did = py_replace_imports(content, old_mod, new_mod, source_package)
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
        vim.api.nvim_buf_call(buf, function()
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
-- Setup
-- ============================================================

function M.setup()
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "neo-tree",
        callback = function(ev)
            vim.keymap.set("n", "<leader>rr", function()
                local filepath, err = get_neotree_file_path()
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
                        local new_path = path_join(dir, new_name)
                        do_rename_and_update(filepath, new_path)

                        pcall(function()
                            require("neo-tree.command").execute({ action = "refresh" })
                        end)
                    end)
                end)
            end, { buffer = ev.buf, desc = "Rename file + update imports" })
        end,
    })
end

return M
