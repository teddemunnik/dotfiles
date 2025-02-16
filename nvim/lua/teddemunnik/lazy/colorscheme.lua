
function ConfigureStyle()
    vim.cmd("colorscheme rose-pine")
    vim.o.guifont = "Fira Code,codicon" 
    vim.g.neovide_transparency = 0.9
    vim.g.neovide_normal_opacity  = 0.95
    vim.g.neovide_cursor_animation_length = 0.08
end

return {
	{
		"rose-pine/neovim",
		config = function()
            ConfigureStyle()
		end
	},
}
