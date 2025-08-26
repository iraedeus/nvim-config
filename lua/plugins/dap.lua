return {
    {
        "mfussenegger/nvim-dap",
        dependencies = {
            {
                "rcarriga/nvim-dap-ui",
                dependencies = { "nvim-neotest/nvim-nio" },
                config = function()
                    local dapui = require("dapui")
                    dapui.setup()

                    local dap = require("dap")
                    dap.listeners.after.event_initialized["dapui_config"] = function()
                        dapui.open()
                    end
                    dap.listeners.before.event_terminated["dapui_config"] = function()
                        dapui.close()
                    end
                    dap.listeners.before.event_exited["dapui_config"] = function()
                        dapui.close()
                    end

                    dap.configurations.python = {
                        {
                            type = 'python', -- Используем адаптер для Python
                            request = 'launch',
                            name = "Debug: Pytest File",
                            -- Ключевой момент: мы запускаем pytest как модуль
                            module = "pytest",
                            -- Аргументы для pytest, например, для вывода print() и подробного лога
                            args = { "-s", "-v", "${file}" },
                            -- Запускать в интегрированном терминале, чтобы видеть вывод
                            console = "integratedTerminal",
                        },
                    }
                end
            },
            {
                "mfussenegger/nvim-dap-python",
                config = function()
                    require("dap-python").setup("python")
                    vim.fn.sign_define('DapBreakpoint', { text = '', texthl = 'Error', linehl = '', numhl = '' })
                end
            },
        }
    }
}
