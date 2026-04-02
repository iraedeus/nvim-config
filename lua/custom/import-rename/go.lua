local M = {}
local utils = require("custom.import-rename.utils")

function M.get_module_name(root)
    local content = utils.read_file(utils.path_join(root, "go.mod"))
    if not content then return nil end
    return content:match("module%s+([%w%._%-/]+)")
end

function M.dir_to_import(root, go_module, dirpath)
    local rel = dirpath:sub(#root + 2)
    if not rel or rel == "" then return go_module end
    return go_module .. "/" .. rel
end

function M.replace_imports(content, old_imp, new_imp)
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

--- Обновляет `package old_name` → `package new_name`
--- Ищет первую строку с package declaration (пропускает комментарии).
function M.replace_package_decl(content, old_name, new_name)
    if old_name == new_name then return content, false end
    local lines = vim.split(content, "\n", { plain = true })
    local changed = false
    for i, line in ipairs(lines) do
        local pre, post = line:match(
            "^(%s*package%s+)" .. vim.pesc(old_name) .. "(%s*)$"
        )
        if pre then
            lines[i] = pre .. new_name .. post
            changed = true
            break -- одна package declaration на файл
        end
    end
    if changed then
        return table.concat(lines, "\n"), true
    end
    return content, false
end

--- Собирает информацию об импортах в файле:
--- возвращает список { import_path, alias_or_nil, pkg_name }
--- pkg_name — имя, используемое в коде (алиас или последний сегмент пути).
function M.parse_imports(content)
    local result = {}

    -- grouped: import ( ... )
    for block in content:gmatch("import%s*%((.-)%)") do
        for line in block:gmatch("[^\n]+") do
            local alias, path = line:match('^%s*(%w+)%s+"([^"]+)"%s*$')
            if not alias then
                path = line:match('^%s*"([^"]+)"%s*$')
            end
            if path then
                local pkg_name = alias or path:match("([^/]+)$")
                result[#result + 1] = {
                    path = path,
                    alias = alias,
                    pkg_name = pkg_name,
                }
            end
        end
    end

    -- single: import "path" or import alias "path"
    for full_line in content:gmatch("[^\n]+") do
        if full_line:match("^%s*import%s+") and not full_line:match("^%s*import%s*%(") then
            local alias, path = full_line:match('^%s*import%s+(%w+)%s+"([^"]+)"%s*$')
            if not alias then
                path = full_line:match('^%s*import%s+"([^"]+)"%s*$')
            end
            if path then
                local pkg_name = alias or path:match("([^/]+)$")
                result[#result + 1] = {
                    path = path,
                    alias = alias,
                    pkg_name = pkg_name,
                }
            end
        end
    end

    return result
end

--- Обновляет использования пакета в коде:
--- `old_name.Func()` → `new_name.Func()`
--- Только для импортов БЕЗ пользовательского алиаса.
function M.replace_usage(content, old_name, new_name)
    if old_name == new_name then return content, false end
    local pat = "(%f[%w_])" .. vim.pesc(old_name) .. "(%s*%.)"
    local repl = "%1" .. new_name .. "%2"
    local new_content, count = content:gsub(pat, repl)
    return new_content, count > 0
end

--- Главная функция: обновляет import path + usage в одном файле.
--- old_imp/new_imp — полные import-пути (e.g. "example.com/proj/core")
--- Возвращает new_content, changed
function M.refactor_file(content, old_imp, new_imp)
    local changed = false

    -- 1. Запоминаем, какие пакеты из старого пути импортированы без алиаса
    local old_dir_name = old_imp:match("([^/]+)$")
    local new_dir_name = new_imp:match("([^/]+)$")

    local imports = M.parse_imports(content)
    local needs_usage_rename = {}

    for _, imp in ipairs(imports) do
        -- проверяем: этот импорт совпадает с old_imp или является его подпакетом?
        if imp.path == old_imp or imp.path:sub(1, #old_imp + 1) == old_imp .. "/" then
            if not imp.alias then
                -- без алиаса — неявно используется имя директории
                local implicit_name = imp.path:match("([^/]+)$")
                if imp.path == old_imp then
                    -- прямой импорт переименовываемого пакета
                    needs_usage_rename[implicit_name] = new_dir_name
                end
                -- для подпакетов implicit_name не меняется (e.g. sub остаётся sub)
            end
        end
    end

    -- 2. Обновляем import paths
    local nc, did = M.replace_imports(content, old_imp, new_imp)
    if did then
        content = nc
        changed = true
    end

    -- 3. Обновляем usage для пакетов без алиаса
    for old_name, new_name in pairs(needs_usage_rename) do
        nc, did = M.replace_usage(content, old_name, new_name)
        if did then
            content = nc
            changed = true
        end
    end

    return content, changed
end

return M
