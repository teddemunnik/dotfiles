return {
    "mfussenegger/nvim-dap",
    "rcarriga/nvim-dap-ui",
    "jay-babu/mason-nvim-dap.nvim",
    dependencies = {
        "mason"
    },
	config = function()
        require("mason-nvim-dap").setup({
            ensure_installed = { "codelldb" },
        });
    end
}
