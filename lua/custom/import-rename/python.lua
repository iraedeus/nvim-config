local M = {}

-- ────────────────────────────────────────────────────────────
-- Module / package helpers
-- ────────────────────────────────────────────────────────────

function M.path_to_module(root, filepath)
    local rel = filepath:sub(#root + 2)
    rel = rel:gsub("%.py$", "")
    rel = rel:gsub("/__init__$", "")
    rel = rel:gsub("/", ".")
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
    local parts = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then return nil end
    local n = #parts - levels_up
    local base = table.concat(parts, ".", 1, n)
    if rel_mod and rel_mod ~= "" then
        return base .. "." .. rel_mod
    end
    return base
end

local function make_relative(source_package, abs_mod, dots)
    if not source_package then return nil, nil end
    local parts = vim.split(source_package, ".", { plain = true })
    local levels_up = dots - 1
    if levels_up >= #parts then return nil, nil end
    local n = #parts - levels_up
    local base = table.concat(parts, ".", 1, n)
    local dots_str = string.rep(".", dots)
    if abs_mod == base then return dots_str, "" end
    local prefix = base .. "."
    if abs_mod:sub(1, #prefix) == prefix then
        return dots_str, abs_mod:sub(#prefix + 1)
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

-- ────────────────────────────────────────────────────────────
-- Multiline block helpers
-- ────────────────────────────────────────────────────────────

local function block_last(lines, start)
    local last = start
    local depth = 0
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
        while lines[last]:match("\\%s*$") and last < #lines do
            last = last + 1
        end
    end
    return last
end

local function join_block(lines, first, last)
    local parts = {}
    for j = first, last do
        local l = lines[j]:gsub("\\%s*$", ""):gsub("[()]", " ")
        parts[#parts + 1] = l
    end
    return table.concat(parts, " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- ────────────────────────────────────────────────────────────
-- Inline import extraction
-- ────────────────────────────────────────────────────────────

local function extract_inline_prefix(line)
    local prefix, rest

    prefix, rest = line:match("^(.-;%s*)(from%s+.*)$")
    if prefix then return prefix, rest end

    prefix, rest = line:match("^(.-;%s*)(import%s+.*)$")
    if prefix then return prefix, rest end

    prefix, rest = line:match("^(.-:%s*)(from%s+.*)$")
    if prefix then return prefix, rest end

    prefix, rest = line:match("^(.-:%s*)(import%s+.*)$")
    if prefix then return prefix, rest end

    return nil, nil
end

-- ────────────────────────────────────────────────────────────
-- Alias detection
-- ────────────────────────────────────────────────────────────

local function name_has_alias(text, name)
    local pat = "%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]%s+as%s+[%w_]+"
    return text:match(pat) ~= nil
end

-- ────────────────────────────────────────────────────────────
-- In-place line replacements
-- ────────────────────────────────────────────────────────────

local function swap_from_module(lines, idx, old_str, new_str)
    local pre, post = lines[idx]:match(
        "^(%s*from%s+)" .. vim.pesc(old_str) .. "(%s+import.*)$"
    )
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
                    lines[j] = pre .. np
                    any = true
                end
            end
        else
            local nl = lines[j]:gsub(pat, repl)
            if nl ~= lines[j] then
                lines[j] = nl
                any = true
            end
        end
    end
    return any
end

-- ────────────────────────────────────────────────────────────
-- __all__ pass

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
                or l:match("__all__%.insert%s*%(")
            then
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
                lines[idx] = nl
                any = true
            end
            if depth <= 0 then in_all = false end
        end
    end
    return any
end

-- ────────────────────────────────────────────────────────────
-- Body refactoring
-- ────────────────────────────────────────────────────────────

local function apply_body_renames(lines, leaf_rename, dotted_renames)
    local utils = require("custom.import-rename.utils")
    local changed = false
    -- Склеиваем весь код в один текст
    local content = table.concat(lines, "\n")

    -- 1. Длинные пути (dotted renames)
    for _, r in ipairs(dotted_renames) do
        local pat     = "(%f[%w_])" .. vim.pesc(r.old) .. "(%f[^%w_])"
        local repl    = "%1" .. r.new .. "%2"
        -- Применяем безопасную замену (не трогает строки и комменты)
        local nc, did = utils.safe_gsub(content, pat, repl, "python")
        if did then
            content = nc
            changed = true
        end
    end

    -- 2. Короткие имена (leaf rename)
    if leaf_rename then
        local pat     = "(%f[%w_])" .. vim.pesc(leaf_rename.old) .. "(%f[^%w_])"
        local repl    = "%1" .. leaf_rename.new .. "%2"
        local nc, did = utils.safe_gsub(content, pat, repl, "python")
        if did then
            content = nc
            changed = true
        end
    end

    -- Если были изменения, возвращаем их обратно в массив lines
    if changed then
        local new_lines = vim.split(content, "\n", { plain = true })
        for i = #lines, 1, -1 do lines[i] = nil end
        for i, l in ipairs(new_lines) do lines[i] = l end
    end

    return changed
end

-- ────────────────────────────────────────────────────────────
-- Main: replace_imports
-- ────────────────────────────────────────────────────────────

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

    -- body refactoring tracking
    local leaf_body_rename = false
    local dotted_renames   = {}

    local i                = 1
    while i <= #lines do
        local line = lines[i]
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
                    local nms = ds and (ds .. rl) or replaced_from
                    if swap_from_module(lines, first, rel_dots .. rel_mod_part, nms) then
                        changed = true
                    end
                elseif old_parent and abs_from == old_parent then
                    local kw = rel_rest:match("^([ \t]+import%s+)")
                    if kw then
                        local need = false
                        if new_parent and old_parent ~= new_parent then
                            local ds, rl = make_relative(source_package, new_parent, ndots)
                            local nms = ds and (ds .. rl) or new_parent
                            if swap_from_module(lines, first, rel_dots .. rel_mod_part, nms) then
                                need = true
                            end
                        end
                        if swap_leaf(lines, first, last, old_leaf, new_leaf) then
                            need = true
                            leaf_swapped = true
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
                    local kw = from_rest:match("^(%s+import%s+)")
                    if kw then
                        local need = false
                        if new_parent and old_parent ~= new_parent then
                            if swap_from_module(lines, first, old_parent, new_parent) then
                                need = true
                            end
                        end
                        if swap_leaf(lines, first, last, old_leaf, new_leaf) then
                            need = true
                            leaf_swapped = true
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
                                -- track dotted body rename (only without alias)
                                if not name_has_alias(joined, mod_name) then
                                    dotted_renames[#dotted_renames + 1] = {
                                        old = mod_name,
                                        new = replaced,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        -- restore inline prefix
        if inline_prefix then
            lines[first] = inline_prefix .. lines[first]
        end

        i = last + 1
        ::continue::
    end

    -- __all__ pass
    if leaf_swapped then
        if update_dunder_all(lines, old_leaf, new_leaf) then
            changed = true
        end
    end

    -- body refactoring pass
    local leaf_r = nil
    if leaf_body_rename and old_leaf ~= new_leaf then
        leaf_r = { old = old_leaf, new = new_leaf }
    end
    if leaf_r or #dotted_renames > 0 then
        if apply_body_renames(lines, leaf_r, dotted_renames) then
            changed = true
        end
    end

    if changed then
        return table.concat(lines, "\n"), true
    end
    return content, false
end

return M
