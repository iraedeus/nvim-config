-- ~/.config/nvim/lua/plugins/alpha.lua

return {
  'goolord/alpha-nvim',
  event = 'VimEnter',
  config = function ()
    local alpha = require('alpha')
    local dashboard = require('alpha.themes.dashboard')
    local custom_header = require('headers.eyes')

    -- Сначала создаем "шапку" (Header) - это и есть наша картинка
    dashboard.config.layout[2] = custom_header.header
    dashboard.section.header.opts.hl = 'YourHighlightGroup' -- Подсветка как у строки

    -- Создаем кнопки (Buttons)
    dashboard.section.buttons.val = {
      dashboard.button("e", "  Новый файл", ":enew<CR>"),
      dashboard.button("f", "  Найти файл", ":Telescope find_files<CR>"),
      dashboard.button("r", "  Недавние файлы", ":Telescope oldfiles<CR>"),
      dashboard.button("g", "  Найти по тексту", ":Telescope live_grep<CR>"),
      dashboard.button("c", "  Конфигурация", ":e $MYVIMRC<CR>"),
      dashboard.button("q", "  Выход", ":qa<CR>"),
    }

    -- Создаем "подвал" (Footer) со случайной цитатой
    local fortune = require('alpha.fortune')
    dashboard.section.footer.val = fortune()
    dashboard.section.footer.opts.hl = 'Comment' -- Подсветка как у комментария

    -- Применяем все наши настройки
    alpha.setup(dashboard.opts)
  end,
  dependencies = { 'nvim-tree/nvim-web-devicons' } -- Для иконок файлов
}
