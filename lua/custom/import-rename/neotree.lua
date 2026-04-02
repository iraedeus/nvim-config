local M = {}

function M.get_node_info()
    if vim.bo.filetype ~= "neo-tree" then
        return nil, nil, "Not in neo-tree"
    end

    local ok, manager = pcall(require, "neo-tree.sources.manager")
    if not ok then return nil, nil, "neo-tree not loaded" end

    local state = manager.get_state("filesystem")
    if not state or not state.tree then return nil, nil, "no tree state" end

    local node = state.tree:get_node()
    if not node then return nil, nil, "no node under cursor" end

    if node.type ~= "file" and node.type ~= "directory" then
        return nil, nil, "Cursor is not on a file or directory"
    end

    return node.path, node.type, nil
end

return M
