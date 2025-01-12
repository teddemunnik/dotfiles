return {
    {
        "nvim-telescope/telescope.nvim",
        dependencies = {
            { 'nvim-telescope/telescope-fzf-native.nvim', build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release' }
        },
        keys = {
            { "<leader>sf", require('telescope.builtin').find_files, desc = "[s]earch [f]iles" },
            { "<leader>sg", require('telescope.builtin').live_grep, desc = "[s]earch [g]rep" },
        },
        config = function(opts)
            require('telescope').setup(opts)
            require('telescope').load_extension('fzf')
        end
    }
}
