return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    spec = {
        { "<leader>s", group = "Search" },
        { "<leader>p", group = "Project" },
    }
  },
  keys = {
    {
      "<leader>?",
      function()
        require("which-key").show({ global = false })
      end,
      desc = "Buffer Local Keymaps (which-key)",
    },
  },
}
