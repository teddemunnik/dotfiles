require("teddemunnik.set")
require("teddemunnik.remap")
require("teddemunnik.lazy_init")

vim.api.nvim_create_autocmd('TextYankPost', {
    desc = 'Highlight when yanking text',
    group = vim.api.nvim_create_augroup('highlight-yank', { clear = true }),
    callback = function()
        vim.highlight.on_yank()
    end
})

vim.lsp.config("lua_ls", {
  cmd = { "lua-language-server" },
  filetypes = { "lua" },
  settings = {
    Lua = {
      diagnostics = { globals = { "vim" } },
      workspace = { checkThirdParty = false },
    },
  },
})

vim.lsp.enable({"lua_ls"})

vim.api.nvim_create_autocmd('LspAttach', {
   group = vim.api.nvim_create_augroup('teddemunnik-lsp-attach', { clear = true }),
   callback = function(event)
       local telescope_builtin = require('telescope.builtin')

       vim.keymap.set('n', 'gd', telescope_builtin.lsp_definitions, { desc = '[G]goto [D]efintion'})
       vim.keymap.set('n', 'gr', telescope_builtin.lsp_references, { desc = '[G]goto [R]eferences'})
       vim.keymap.set('n', 'gI', telescope_builtin.lsp_implementations, { desc = '[G]oto [I]mplemtation'})
       vim.keymap.set('n', 'gt', telescope_builtin.lsp_type_definitions, { desc = '[G]oto [T]ype Definition'})
       vim.keymap.set('n', '<M-CR>', vim.lsp.buf.code_action, { desc = 'Code Action' })
       vim.keymap.set('n', 'ff', vim.lsp.buf.format, { desc = 'Format File' })

       local client = vim.lsp.get_client_by_id(event.data.client_id)
       if client and client.supports_method(vim.lsp.protocol.Methods.textDocument_inlayHint) then
           vim.keymap.set('n', '<leader>th', function()
               vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
           end, { desc = '[T]oggle Inlay [H]ints'})
       end
   end
});

