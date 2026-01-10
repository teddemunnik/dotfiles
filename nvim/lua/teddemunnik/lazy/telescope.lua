return {
    {
        "nvim-telescope/telescope.nvim",
        dependencies = {
            { 'nvim-telescope/telescope-fzf-native.nvim', build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release' }
        },
        keys = {
            { "<leader>sf", function() require('telescope.builtin').find_files() end, desc = "Search Files" },
            { "<leader>sg", function() require('telescope.builtin').live_grep() end,  desc = "Search using Grep" },
            { "<leader>sb", function() require('telescope.builtin').buffers() end,    desc = "Search buffers" },
        },
        config = function(opts)
            require('telescope').setup(opts)
            require('telescope').load_extension('fzf')
        end
    }
}
