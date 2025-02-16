return {
    {
        "nvim-telescope/telescope.nvim",
        dependencies = {
            { 'nvim-telescope/telescope-fzf-native.nvim', build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release' }
        },
        keys = {
            { "<leader>sf", function() require('telescope.builtin').find_files() end, desc = "[s]earch [f]iles" },
            { "<leader>sg", function() require('telescope.builtin').live_grep() end, desc = "[s]earch [g]rep" },
        },
        config = function(opts)
            require('telescope').setup(opts)
            require('telescope').load_extension('fzf')
        end
    }
}
