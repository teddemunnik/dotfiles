return {
    {
        "mfussenegger/nvim-dap",
        lazy = false,
        keys = {
            { "<F9>", function() require('dap').toggle_breakpoint() end },
            { "<F5>", function() require('dap').continue() end },
            { "<F10>", function() require('dap').step_over() end },
            { "<F11>", function() require('dap').step_into() end },
            { "<S-F11>", function() require('dap').step_out() end },
            --{ "<S-F5>", function() require('dap').step_out() end },
            { mode = {"n", "v"}, "<leader>dh", function() require('dap.ui.widgets').hover() end },
            { mode = {"n", "v"}, "<leader>dp", function() require('dap.ui.widgets').preview() end },
            { 
                "<leader>df",
                function() 
                    local widgets = require('dap.ui.widgets')
                    widgets.centered_float(widgets.frames)
                end
            },
            { 
                "<leader>ds",
                function()
                    local widgets = require('dap.ui.widgets')
                    widgets.centered_float(widgets.scopes)
                end
            }
        },
        config = function()
            local dap = require('dap')
            dap.adapters["lldb-dap"] = {
                type = 'executable',
                command = 'lldb-dap',
                name = 'lldb-dap'
            }
        end
    },
    "nvim-neotest/nvim-nio",
    {
        "rcarriga/nvim-dap-ui",
        lazy = false,
        config = true
    }
}
