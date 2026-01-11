function ConfigureStyle()
    vim.g.moonflyTransparent = true
    vim.cmd("colorscheme moonfly")
    vim.o.guifont                         = "FiraCode Nerd Font"
    vim.g.neovide_transparency            = 0.9
    vim.g.neovide_normal_opacity          = 0.95
    vim.g.neovide_cursor_animation_length = 0.08
end

return {
    {
        "bluz71/vim-moonfly-colors",
        name = "moonfly",
        lazy = false,
        priority = 1000,
        config = function()
            ConfigureStyle()
        end
    },
}
