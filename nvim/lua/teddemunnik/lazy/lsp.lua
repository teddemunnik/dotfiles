return {
	"williamboman/mason-lspconfig.nvim",
	dependencies = {
		"williamboman/mason.nvim",
		"neovim/nvim-lspconfig",
		"j-hui/fidget.nvim",
        "hrsh7th/cmp-nvim-lsp",
        "hrsh7th/cmp-buffer",
        "hrsh7th/cmp-path",
        "hrsh7th/cmp-cmdline",
        "hrsh7th/nvim-cmp",
	},
	config = function()
        vim.api.nvim_create_autocmd('LspAttach', {
            group = vim.api.nvim_create_augroup('teddemunnik-lsp-attach', { clear = true }),
            callback = function(event)
                local telescope_builtin = require('telescope.builtin')

                vim.keymap.set('n', 'gd', telescope_builtin.lsp_definitions, { desc = '[G]goto [D]efintion'})
                vim.keymap.set('n', 'gr', telescope_builtin.lsp_references, { desc = '[G]goto [R]eferences'})
                vim.keymap.set('n', 'gI', telescope_builtin.lsp_implementations, { desc = '[G]oto [I]mplemtation'})
                vim.keymap.set('n', 'gt', telescope_builtin.lsp_type_definitions, { desc = '[G]oto [T]ype Definition'}) 

                local client = vim.lsp.get_client_by_id(event.data.client_id)
                if client and client.supports_method(vim.lsp.protocol.Methods.textDocument_inlayHint) then
                    vim.keymap.set('n', '<leader>th', function()
                        vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
                    end, { desc = '[T]oggle Inlay [H]ints'})
                end
            end
        });

		require("mason").setup()

        -- Set up nvim-cmp.
        local cmp = require'cmp'

        cmp.setup({
            snippet = {
                -- REQUIRED - you must specify a snippet engine
                expand = function(args)
                    vim.snippet.expand(args.body)
                end,
            },
            window = {
                -- completion = cmp.config.window.bordered(),
                -- documentation = cmp.config.window.bordered(),
            },
            mapping = cmp.mapping.preset.insert({
                ['<C-b>'] = cmp.mapping.scroll_docs(-4),
                ['<C-f>'] = cmp.mapping.scroll_docs(4),
                ['<C-Space>'] = cmp.mapping.complete(),
                ['<C-e>'] = cmp.mapping.abort(),
                ['<CR>'] = cmp.mapping.confirm({ select = true }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
            }),
            sources = cmp.config.sources({
                { name = 'nvim_lsp' },
            }, {
                { name = 'buffer' },
            })
        })

        local capabilities = require('cmp_nvim_lsp').default_capabilities()

        require("mason-lspconfig").setup({
            handlers = { 
                function(server_name)
                    require("lspconfig")[server_name].setup({
                        capabilities = capabilities
                    })
                end,
            },
            ensure_installed = {
                "lua_ls", 
                "rust_analyzer"
            },
        })
		require("fidget").setup({})

	end
}
