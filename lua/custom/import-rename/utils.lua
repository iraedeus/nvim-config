local M = {}
local uv = vim.uv or vim.loop

-- ─── backup storage ────────────────────────────────────────

local _backup = nil

function M.save_backup(data)
    _backup = vim.tbl_extend("force", { timestamp = os.time() }, data)
end

function M.get_backup()
    return _backup
end

function M.clear_backup()
    _backup = nil
end

-- ─── target validation ────────────────────────────────────

function M.target_exists(path)
    return uv.fs_stat(path) ~= nil
end

-- ─── path helpers ──────────────────────────────────────────

function M.path_join(...)
    return table.concat({ ... }, "/"):gsub("//+", "/")
end

function M.find_project_root(start_path)
    local markers = {
        "pyproject.toml", "setup.py", "setup.cfg",
        "go.mod", ".git",
    }
    local path = start_path
    while path and path ~= "/" do
        for _, m in ipairs(markers) do
            local c = M.path_join(path, m)
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

local skip_dirs = {
    "__pycache__", ".git", ".venv", "venv", "env",
    "node_modules", "vendor", "build", "dist",
}

function M.collect_files(dir, extensions)
    local results = {}
    local function scan(d)
        local handle = uv.fs_scandir(d)
        if not handle then return end
        while true do
            local name, ftype = uv.fs_scandir_next(handle)
            if not name then break end
            local full = M.path_join(d, name)
            if not ftype then
                local stat = uv.fs_stat(full)
                ftype = stat and stat.type
            end
            if ftype == "directory" then
                local skip = false
                for _, s in ipairs(skip_dirs) do
                    if name == s then
                        skip = true; break
                    end
                end
                if not skip and name:sub(1, 1) ~= "." then scan(full) end
            elseif ftype == "file" then
                for _, ext in ipairs(extensions) do
                    if name:sub(- #ext) == ext then
                        results[#results + 1] = full
                        break
                    end
                end
            end
        end
    end
    scan(dir)
    return results
end

function M.read_file(filepath)
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

function M.write_file(filepath, data)
    local fd = uv.fs_open(filepath, "w", 438)
    if not fd then return false end
    uv.fs_write(fd, data)
    uv.fs_close(fd)
    return true
end

function M.reload_buffer(filepath)
    local bufnr = vim.fn.bufnr(filepath)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            if not vim.bo[bufnr].modified then
                vim.cmd("silent! edit!")
            end
        end)
    end
end

-- ─── Treesitter safe substitution (Range-based) ────────────

local ts = vim.treesitter

--- Применяет gsub, игнорируя участки, попавшие в строки или комментарии
function M.safe_gsub(content, pattern, repl, filetype)
    local ok, parser = pcall(ts.get_string_parser, content, filetype)
    if not ok or not parser then
        local nc, c = content:gsub(pattern, repl)
        return nc, c > 0
    end

    local tree = parser:parse()[1]
    if not tree then
        local nc, c = content:gsub(pattern, repl)
        return nc, c > 0
    end

    local query_str = filetype == "python"
        and "(string) @ignore (comment) @ignore (interpolation) @unignore"
        or "(comment) @ignore (interpreted_string_literal) @ignore (raw_string_literal) @ignore (rune_literal) @ignore"

    local ok_q, query = pcall(ts.query.parse, filetype, query_str)
    if not ok_q or not query then
        local nc, c = content:gsub(pattern, repl)
        return nc, c > 0
    end

    -- Собираем только координаты диапазонов (это крошечные массивы)
    local ignore_ranges = {}
    local unignore_ranges = {}

    for id, node in query:iter_captures(tree:root(), content) do
        local name = query.captures[id]
        local _, _, s = node:start()
        local _, _, e = node:end_()
        if name == "ignore" then
            table.insert(ignore_ranges, { s = s + 1, e = e })
        elseif name == "unignore" then
            table.insert(unignore_ranges, { s = s + 1, e = e })
        end
    end

    local changed = false
    -- Трюк Lua: пустые скобки () возвращают индекс начала совпадения
    local safe_pattern = "()(" .. pattern .. ")"

    local new_content = content:gsub(safe_pattern, function(pos, full_match)
        local is_ignored = false

        -- Проверяем, попало ли слово внутрь строки/комментария
        for _, r in ipairs(ignore_ranges) do
            if pos >= r.s and pos <= r.e then
                is_ignored = true
                break
            end
        end

        -- Если это f-строка, проверяем, не попали ли мы в её интерполяцию {...}
        if is_ignored then
            for _, r in ipairs(unignore_ranges) do
                if pos >= r.s and pos <= r.e then
                    is_ignored = false
                    break
                end
            end
        end

        if is_ignored then return nil end -- пропускаем замену

        changed = true
        return full_match:gsub(pattern, repl)
    end)

    return new_content, changed
end

return M
