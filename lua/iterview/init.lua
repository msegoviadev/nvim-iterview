local M = {}

M.config = {
  max_checkpoints = 20,
  storage_dir = ".iterview",
  auto_gitignore = true,
  git_search_depth = 2,
  exclude_dirs = {
    "node_modules", ".venv", "target", "dist", "build", "__pycache__",
  },
  telescope = {
    layout_strategy = "vertical",
    layout_config = {
      height = 0.95,
      width = 0.8,
      preview_height = 0.6,
    },
  },
  keymaps = {
    checkpoint = "<leader>ic",
    diff = "<leader>id",
    history = "<leader>ih",
    clear = "<leader>ix",
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local snapshot = require("iterview.snapshot")
  local telescope = require("iterview.telescope")
  local utils = require("iterview.utils")

  -- Register user commands
  vim.api.nvim_create_user_command("IterviewCheckpoint", function()
    utils.notify("creating checkpoint...")
    snapshot.create_checkpoint(M.config, function(id, file_count)
      if id then
        utils.notify(
          "checkpoint #" .. id .. " created"
          .. " | " .. file_count .. " files tracked"
          .. " | " .. os.date("%H:%M:%S")
        )
      end
    end)
  end, { desc = "Create an iterview checkpoint" })

  vim.api.nvim_create_user_command("IterviewDiff", function(cmd_opts)
    local checkpoint_id = nil
    if cmd_opts.args and cmd_opts.args ~= "" then
      checkpoint_id = tonumber(cmd_opts.args)
    end

    if not checkpoint_id then
      local latest = snapshot.get_latest_checkpoint(M.config)
      if not latest then
        utils.notify("no checkpoints yet. Use <Space>ic to create one.")
        return
      end
      checkpoint_id = latest.id
    end

    telescope.diff_picker(M.config, checkpoint_id)
  end, {
    desc = "Show changes since last checkpoint",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("IterviewHistory", function()
    telescope.history_picker(M.config)
  end, { desc = "Browse checkpoint history" })

  vim.api.nvim_create_user_command("IterviewClear", function()
    local count = snapshot.clear_checkpoints(M.config)
    snapshot.invalidate_cache()
    utils.notify(count .. " checkpoints cleared")
  end, { desc = "Clear all checkpoints" })

  -- Register keymaps
  local keymaps = M.config.keymaps
  if keymaps.checkpoint then
    vim.keymap.set("n", keymaps.checkpoint, "<cmd>IterviewCheckpoint<CR>", {
      desc = "[I]terview [C]heckpoint",
    })
  end
  if keymaps.diff then
    vim.keymap.set("n", keymaps.diff, "<cmd>IterviewDiff<CR>", {
      desc = "[I]terview [D]iff",
    })
  end
  if keymaps.history then
    vim.keymap.set("n", keymaps.history, "<cmd>IterviewHistory<CR>", {
      desc = "[I]terview [H]istory",
    })
  end
  if keymaps.clear then
    vim.keymap.set("n", keymaps.clear, "<cmd>IterviewClear<CR>", {
      desc = "[I]terview Clear(x)",
    })
  end
end

return M
