local M = {}

function M.get_file_path()
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

return M
