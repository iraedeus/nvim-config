local M     = {}
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
    local ok, parser = pcall(vim.treesitter.get_string_parser, content, "go")
    if not ok or not parser then return content, false end

    local tree = parser:parse()[1]
    local query = vim.treesitter.query.parse("go",
        [[ (import_spec path: (interpreted_string_literal) @path) ]])
    local replacements = {}

    for _, node in query:iter_captures(tree:root(), content) do
        local _, _, s = node:start()
        local _, _, e = node:end_()
        local path = content:sub(s + 2, e - 1)

        local new_text
        if path == old_imp then
            new_text = '"' .. new_imp .. '"'
        elseif path:sub(1, #old_imp + 1) == old_imp .. "/" then
            new_text = '"' .. new_imp .. path:sub(#old_imp + 1) .. '"'
        end

        if new_text then
            replacements[#replacements + 1] = { s = s, e = e, t = new_text }
        end
    end

    if #replacements == 0 then return content, false end

    table.sort(replacements, function(a, b) return a.s > b.s end)
    for _, r in ipairs(replacements) do
        content = content:sub(1, r.s) .. r.t .. content:sub(r.e + 1)
    end
    return content, true
end

function M.replace_usage(content, old_name, new_name)
    if old_name == new_name then return content, false end
    local pat  = "(%f[%w_])" .. vim.pesc(old_name) .. "(%s*%.)"
    local repl = "%1" .. new_name .. "%2"
    return utils.safe_gsub(content, pat, repl, "go")
end

function M.replace_package_decl(content, old_name, new_name)
    if old_name == new_name then return content, false end
    local lines = vim.split(content, "\n", { plain = true })
    for i, line in ipairs(lines) do
        local pre, post = line:match(
            "^(%s*package%s+)" .. vim.pesc(old_name) .. "(%s*)$")
        if pre then
            lines[i] = pre .. new_name .. post
            return table.concat(lines, "\n"), true
        end
    end
    return content, false
end

function M.parse_imports(content)
    local result = {}
    local function add(alias, path)
        result[#result + 1] = {
            path     = path,
            alias    = alias,
            pkg_name = alias or path:match("([^/]+)$"),
        }
    end

    for block in content:gmatch("import%s*%((.-)%)") do
        for line in block:gmatch("[^\n]+") do
            local a, p = line:match('^%s*(%w+)%s+"([^"]+)"%s*$')
            if not a then p = line:match('^%s*"([^"]+)"%s*$') end
            if p then add(a, p) end
        end
    end

    for full_line in content:gmatch("[^\n]+") do
        if full_line:match("^%s*import%s+") and not full_line:match("^%s*import%s*%(") then
            local a, p = full_line:match('^%s*import%s+(%w+)%s+"([^"]+)"%s*$')
            if not a then p = full_line:match('^%s*import%s+"([^"]+)"%s*$') end
            if p then add(a, p) end
        end
    end

    return result
end

function M.refactor_file(content, old_imp, new_imp)
    local changed      = false
    local new_dir_name = new_imp:match("([^/]+)$")

    local needs_rename = {}
    for _, imp in ipairs(M.parse_imports(content)) do
        if not imp.alias and imp.path == old_imp then
            needs_rename[imp.path:match("([^/]+)$")] = new_dir_name
        end
    end

    local nc, did = M.replace_imports(content, old_imp, new_imp)
    if did then
        content = nc; changed = true
    end

    for old_name, new_name in pairs(needs_rename) do
        nc, did = M.replace_usage(content, old_name, new_name)
        if did then
            content = nc; changed = true
        end
    end

    return content, changed
end

function M.collect_pending(root, old_path, new_path, is_dir)
    if not is_dir and not old_path:match("%.go$") then return {} end

    local go_mod = M.get_module_name(root)
    if not go_mod then return {} end

    local old_dir = is_dir and old_path or vim.fn.fnamemodify(old_path, ":h")
    local new_dir = is_dir and new_path or vim.fn.fnamemodify(new_path, ":h")
    local old_imp = M.dir_to_import(root, go_mod, old_dir)
    local new_imp = M.dir_to_import(root, go_mod, new_dir)
    if old_imp == new_imp then return {} end

    local pending      = {}
    local old_prefix   = is_dir and (old_path .. "/") or nil
    local old_dir_name = is_dir and old_path:match("([^/]+)$") or nil
    local new_dir_name = is_dir and new_path:match("([^/]+)$") or nil

    for _, fp in ipairs(utils.collect_files(root, { ".go" })) do
        if fp ~= old_path and fp ~= new_path then
            local content = utils.read_file(fp)
            if content then
                local original = content
                local did_any  = false

                if is_dir and fp:sub(1, #old_prefix) == old_prefix
                    and not fp:sub(#old_prefix + 1):find("/") then
                    local nc, did = M.replace_package_decl(
                        content, old_dir_name, new_dir_name)
                    if did then
                        content = nc; did_any = true
                    end
                end

                local nc, did = M.refactor_file(content, old_imp, new_imp)
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

    -- Package decl в самом перемещаемом файле (move в другую директорию)
    if not is_dir then
        local old_pkg = old_dir:match("([^/]+)$")
        local new_pkg = new_dir:match("([^/]+)$")
        if old_pkg and new_pkg and old_pkg ~= new_pkg then
            local content = utils.read_file(old_path)
            if content then
                local nc, did = M.replace_package_decl(content, old_pkg, new_pkg)
                if did then
                    pending[#pending + 1] = {
                        filepath = old_path, original = content, modified = nc,
                    }
                end
            end
        end
    end

    return pending
end

return M
