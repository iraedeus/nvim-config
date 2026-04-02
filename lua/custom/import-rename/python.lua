local M     = {}
local utils = require("custom.import-rename.utils")

function M.path_to_module(root, filepath)
    local rel = filepath:sub(#root + 2)
    rel = rel:gsub("%.py$", ""):gsub("/__init__$", ""):gsub("/", ".")
    return rel
end

function M.get_package(root, filepath)
    local is_init = filepath:match("/__init__%.py$") ~= nil
    local mod = M.path_to_module(root, filepath)
    if is_init then return mod end
    local parts = vim.split(mod, ".", { plain = true })
    if #parts <= 1 then return nil end
    return table.concat(parts, ".", 1, #parts - 1)
end

local function resolve_relative(source_package, dots, rel_mod)
    if not source_package then return nil end
    local parts     = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then return nil end
    local base = table.concat(parts, ".", 1, #parts - levels_up)
    if rel_mod and rel_mod ~= "" then return base .. "." .. rel_mod end
    return base
end

local function make_relative(source_package, abs_mod, dots)
    if not source_package then return nil, nil end
    local parts     = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then return nil, nil end
    local base    = table.concat(parts, ".", 1, #parts - levels_up)
    local dot_str = string.rep(".", dots)
    if abs_mod == base then return dot_str, "" end
    local prefix = base .. "."
    if abs_mod:sub(1, #prefix) == prefix then
        return dot_str, abs_mod:sub(#prefix + 1)
    end
    return nil, nil
end

local function replace_module_ref(text, old_mod, new_mod)
    if text == old_mod then return new_mod, true end
    local prefix = old_mod .. "."
    if text:sub(1, #prefix) == prefix then
        return new_mod .. text:sub(#old_mod + 1), true
    end
    return text, false
end


local function block_last(lines, start)
    local last, depth = start, 0
    for c in lines[start]:gmatch(".") do
        if c == "(" then depth = depth + 1 end
        if c == ")" then depth = depth - 1 end
    end
    if depth > 0 then
        while depth > 0 and last < #lines do
            last = last + 1
            for c in lines[last]:gmatch(".") do
                if c == "(" then depth = depth + 1 end
                if c == ")" then depth = depth - 1 end
            end
        end
    elseif lines[start]:match("\\%s*$") then
        while lines[last]:match("\\%s*$") and last < #lines do last = last + 1 end
    end
    return last
end

local function join_block(lines, first, last)
    local parts = {}
    for j = first, last do
        parts[#parts + 1] = lines[j]:gsub("\\%s*$", ""):gsub("[()]", " ")
    end
    return table.concat(parts, " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end


local function extract_inline_prefix(line)
    for _, sep in ipairs({ ";%s*", ":%s*" }) do
        for _, kw in ipairs({ "from%s+", "import%s+" }) do
            local p, r = line:match("^(.-" .. sep .. ")(" .. kw .. ".*)$")
            if p then return p, r end
        end
    end
    return nil, nil
end


local function name_has_alias(text, name)
    return text:match("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]%s+as%s+[%w_]+") ~= nil
end


local function swap_from_module(lines, idx, old_str, new_str)
    local pre, post = lines[idx]:match(
        "^(%s*from%s+)" .. vim.pesc(old_str) .. "(%s+import.*)$")
    if not pre then
        local s, e = lines[idx]:find(vim.pesc(old_str))
        if s then
            local before = lines[idx]:sub(1, s - 1)
            if before:match("^%s*from%s+$") then
                pre  = before
                post = lines[idx]:sub(e + 1)
            end
        end
    end
    if pre then
        lines[idx] = pre .. new_str .. post
        return true
    end
    return false
end

local function swap_leaf(lines, first, last, oname, nname)
    if oname == nname then return false end
    local pat  = "(%f[%w_])" .. vim.pesc(oname) .. "(%f[^%w_])"
    local repl = "%1" .. nname .. "%2"
    local any  = false
    for j = first, last do
        if j == first then
            local pre, post = lines[j]:match("^(.-import%s)(.*)")
            if pre and post then
                local np = post:gsub(pat, repl)
                if np ~= post then
                    lines[j] = pre .. np; any = true
                end
            end
        else
            local nl = lines[j]:gsub(pat, repl)
            if nl ~= lines[j] then
                lines[j] = nl; any = true
            end
        end
    end
    return any
end


local function update_dunder_all(lines, old_leaf, new_leaf)
    if old_leaf == new_leaf then return false end
    local in_all  = false
    local depth   = 0
    local dq_pat  = '"' .. vim.pesc(old_leaf) .. '"'
    local sq_pat  = "'" .. vim.pesc(old_leaf) .. "'"
    local dq_repl = '"' .. new_leaf .. '"'
    local sq_repl = "'" .. new_leaf .. "'"
    local any     = false

    for idx = 1, #lines do
        local l = lines[idx]
        if not in_all then
            if l:match("^%s*__all__%s*%+?%s*=%s*[%[%(]")
                or l:match("^%s*__all__%s*:.-=%s*[%[%(]")
                or l:match("__all__%.append%s*%(")
                or l:match("__all__%.extend%s*%(")
                or l:match("__all__%.insert%s*%(") then
                in_all = true
                depth  = 0
            end
        end
        if in_all then
            for c in l:gmatch(".") do
                if c == "[" or c == "(" then depth = depth + 1 end
                if c == "]" or c == ")" then depth = depth - 1 end
            end
            local nl = l:gsub(dq_pat, dq_repl):gsub(sq_pat, sq_repl)
            if nl ~= l then
                lines[idx] = nl; any = true
            end
            if depth <= 0 then in_all = false end
        end
    end
    return any
end


local function apply_body_renames(lines, leaf_rename, dotted_renames)
    local changed = false
    local content = table.concat(lines, "\n")

    for _, r in ipairs(dotted_renames) do
        local pat     = "(%f[%w_])" .. vim.pesc(r.old) .. "(%f[^%w_])"
        local repl    = "%1" .. r.new .. "%2"
        local nc, did = utils.safe_gsub(content, pat, repl, "python")
        if did then
            content = nc; changed = true
        end
    end

    if leaf_rename then
        local pat     = "(%f[%w_])" .. vim.pesc(leaf_rename.old) .. "(%f[^%w_])"
        local repl    = "%1" .. leaf_rename.new .. "%2"
        local nc, did = utils.safe_gsub(content, pat, repl, "python")
        if did then
            content = nc; changed = true
        end
    end

    if changed then
        local new_lines = vim.split(content, "\n", { plain = true })
        for i = #lines, 1, -1 do lines[i] = nil end
        for i, l in ipairs(new_lines) do lines[i] = l end
    end
    return changed
end

function M.replace_imports(content, old_mod, new_mod, source_package)
    local changed          = false
    local leaf_swapped     = false
    local lines            = vim.split(content, "\n", { plain = true })

    local old_parts        = vim.split(old_mod, ".", { plain = true })
    local new_parts        = vim.split(new_mod, ".", { plain = true })
    local old_leaf         = old_parts[#old_parts]
    local new_leaf         = new_parts[#new_parts]
    local old_parent       = #old_parts > 1
        and table.concat(old_parts, ".", 1, #old_parts - 1) or nil
    local new_parent       = #new_parts > 1
        and table.concat(new_parts, ".", 1, #new_parts - 1) or nil

    local leaf_body_rename = false
    local dotted_renames   = {}

    local i                = 1
    while i <= #lines do
        local line          = lines[i]
        local inline_prefix = nil

        if not (line:match("^%s*from%s+") or line:match("^%s*import%s+")) then
            local prefix, rest = extract_inline_prefix(line)
            if prefix then
                inline_prefix = prefix
                lines[i] = rest
                line = rest
            else
                i = i + 1
                goto continue
            end
        end

        local first                               = i
        local last                                = block_last(lines, first)
        local joined                              = join_block(lines, first, last)

        -- relative from-import
        local _, rel_dots, rel_mod_part, rel_rest =
            joined:match("^(%s*from%s+)(%.+)([%w_%.]*)([ \t]+import.*)$")

        if rel_dots and source_package then
            local ndots    = #rel_dots
            local abs_from = resolve_relative(source_package, ndots, rel_mod_part)
            if abs_from then
                local replaced_from, did_from =
                    replace_module_ref(abs_from, old_mod, new_mod)

                if did_from then
                    local ds, rl = make_relative(source_package, replaced_from, ndots)
                    local nms    = ds and (ds .. rl) or replaced_from
                    if swap_from_module(lines, first, rel_dots .. rel_mod_part, nms) then
                        changed = true
                    end
                elseif old_parent and abs_from == old_parent then
                    if rel_rest:match("^([ \t]+import%s+)") then
                        local need = false
                        if new_parent and old_parent ~= new_parent then
                            local ds, rl = make_relative(source_package, new_parent, ndots)
                            local nms    = ds and (ds .. rl) or new_parent
                            if swap_from_module(lines, first,
                                    rel_dots .. rel_mod_part, nms) then
                                need = true
                            end
                        end
                        if swap_leaf(lines, first, last, old_leaf, new_leaf) then
                            need = true; leaf_swapped = true
                            if not name_has_alias(joined, old_leaf) then
                                leaf_body_rename = true
                            end
                        end
                        if need then changed = true end
                    end
                end
            end
        else
            -- absolute from-import
            local _, from_mod, from_rest =
                joined:match("^(%s*from%s+)([%w_%.]+)(%s+import.*)$")

            if from_mod then
                local replaced, did = replace_module_ref(from_mod, old_mod, new_mod)
                if did then
                    if swap_from_module(lines, first, from_mod, replaced) then
                        changed = true
                    end
                elseif old_parent and from_mod == old_parent then
                    if from_rest:match("^(%s+import%s+)") then
                        local need = false
                        if new_parent and old_parent ~= new_parent then
                            if swap_from_module(lines, first, old_parent, new_parent) then
                                need = true
                            end
                        end
                        if swap_leaf(lines, first, last, old_leaf, new_leaf) then
                            need = true; leaf_swapped = true
                            if not name_has_alias(joined, old_leaf) then
                                leaf_body_rename = true
                            end
                        end
                        if need then changed = true end
                    end
                end
            else
                -- plain import
                local imp_list = joined:match("^%s*import%s+(.+)$")
                if imp_list then
                    for _, m in ipairs(vim.split(imp_list, ",", { plain = true })) do
                        local mod_name = vim.trim(m):match("^([%w_%.]+)")
                        if mod_name then
                            local replaced, did = replace_module_ref(mod_name, old_mod, new_mod)
                            if did then
                                for j = first, last do
                                    local nl = lines[j]:gsub(vim.pesc(mod_name), replaced, 1)
                                    if nl ~= lines[j] then lines[j] = nl end
                                end
                                changed = true
                                if not name_has_alias(joined, mod_name) then
                                    dotted_renames[#dotted_renames + 1] = {
                                        old = mod_name, new = replaced,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        if inline_prefix then lines[first] = inline_prefix .. lines[first] end

        i = last + 1
        ::continue::
    end

    if leaf_swapped then
        if update_dunder_all(lines, old_leaf, new_leaf) then changed = true end
    end

    local leaf_r = (leaf_body_rename and old_leaf ~= new_leaf)
        and { old = old_leaf, new = new_leaf } or nil
    if leaf_r or #dotted_renames > 0 then
        if apply_body_renames(lines, leaf_r, dotted_renames) then changed = true end
    end

    if changed then return table.concat(lines, "\n"), true end
    return content, false
end

function M.collect_pending(root, old_path, new_path, is_dir)
    if not is_dir and not old_path:match("%.py$") then return {} end

    local old_mod = M.path_to_module(root, old_path)
    local new_mod = M.path_to_module(root, new_path)
    if old_mod == new_mod then return {} end

    local pending    = {}
    local old_prefix = is_dir and (old_path .. "/") or nil

    for _, fp in ipairs(utils.collect_files(root, { ".py" })) do
        if fp ~= old_path and fp ~= new_path then
            local content = utils.read_file(fp)
            if content then
                local pkg
                if is_dir and fp:sub(1, #old_prefix) == old_prefix then
                    local projected = new_path .. "/" .. fp:sub(#old_prefix + 1)
                    pkg = M.get_package(root, projected)
                else
                    pkg = M.get_package(root, fp)
                end
                local nc, did = M.replace_imports(content, old_mod, new_mod, pkg)
                if did then
                    pending[#pending + 1] = {
                        filepath = fp, original = content, modified = nc,
                    }
                end
            end
        end
    end

    return pending
end

return M
