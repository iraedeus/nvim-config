-- Переключение между окнами
vim.keymap.set('n', '<C-h>', '<C-w>h', { desc = 'Move to left window', remap = true })
vim.keymap.set('n', '<C-j>', '<C-w>j', { desc = 'Move to lower window', remap = true })
vim.keymap.set('n', '<C-k>', '<C-w>k', { desc = 'Move to upper window', remap = true })
vim.keymap.set('n', '<C-l>', '<C-w>l', { desc = 'Move to right window', remap = true })

-- Выход из normal режима
vim.keymap.set('i', 'jk', '<Esc>', { noremap = true, silent = true })

-- Сохранение файла
vim.keymap.set('n', '<leader>w', ':w<CR>', { desc = 'Save file' })

-- Neotree
vim.keymap.set('n', '<leader>n', ':Neotree toggle<CR>', { desc = 'Neotree open file manager' })
vim.keymap.set('n', '<leader>b', ':Neotree buffers toggle<CR>', { desc = 'Neotree open buffers' })

-- Telescope
local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Telescope find files' })
vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Telescope live grep' })
vim.keymap.set('n', '<leader>fb', builtin.current_buffer_fuzzy_find, { desc = 'Поиск по текущему буферу' })
vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Telescope help tags' })
vim.keymap.set('n', '<leader>gs', builtin.git_status, { desc = 'Telescope git status' })
vim.keymap.set('n', '<leader>gc', builtin.git_commits, { desc = 'Telescope git commits' })
vim.keymap.set('n', '<leader>gb', builtin.git_branches, { desc = 'Telescope git branches' })

-- LSP saga
vim.keymap.set('n', 'gd', '<cmd>Lspsaga peek_definition<CR>', { desc = 'LSP saga go to definition' })
vim.keymap.set('n', 'gi', '<cmd>Lspsaga peek_implementation<CR>', { desc = 'LSP saga implementation' })
vim.keymap.set('n', 'gr', '<cmd>Lspsaga finder<CR>', { desc = 'LSP saga references' })
vim.keymap.set('n', 'K', '<cmd>Lspsaga hover_doc<CR>', { desc = 'LSP saga hover docs' })
