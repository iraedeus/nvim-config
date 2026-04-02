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

return M
