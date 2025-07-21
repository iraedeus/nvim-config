local opt = vim.opt

vim.o.termguicolors = true

vim.g.mapleader = ' '
vim.g.maplocleader = '\\'

-- Файлы и история изменений
opt.swapfile = false
opt.backup = false
local undodir = vim.fn.stdpath('data') .. '/undodir'
if vim.fn.isdirectory(undodir) == 0 then
    vim.fn.mkdir(undodir, 'p')
end
opt.undodir = undodir
opt.undofile = true

-- Интерфейс
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.termguicolors = true
opt.signcolumn = 'yes'
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.cmdheight = 2
opt.list = true
opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
opt.wrap = false

-- Отступы
opt.expandtab = true
opt.tabstop = 4
opt.softtabstop = 4
opt.shiftwidth = 4
opt.smartindent = true

-- Отключение мыши
opt.mouse = ''
