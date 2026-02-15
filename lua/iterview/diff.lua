local utils = require("iterview.utils")
local snapshot = require("iterview.snapshot")

local M = {}

function M.compute_diff(old_content, new_content)
  old_content = old_content or ""
  new_content = new_content or ""

  -- Ensure trailing newline for clean diffs
  if old_content ~= "" and old_content:sub(-1) ~= "\n" then
    old_content = old_content .. "\n"
  end
  if new_content ~= "" and new_content:sub(-1) ~= "\n" then
    new_content = new_content .. "\n"
  end

  local diff = vim.diff(old_content, new_content, {
    result_type = "unified",
    algorithm = "patience",
  })

  -- Count insertions and deletions from the diff output
  local insertions = 0
  local deletions = 0
  if diff then
    for line in diff:gmatch("[^\n]+") do
      if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        insertions = insertions + 1
      elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        deletions = deletions + 1
      end
    end
  end

  return {
    diff = diff or "",
    insertions = insertions,
    deletions = deletions,
  }
end

function M.get_change_stats(config, change)
  local old_content = nil
  local new_content = nil

  if change.old_hash then
    old_content = snapshot.get_file_at_checkpoint(
      config,
      change.checkpoint_id,
      change.repo,
      change.path
    )
  end

  if change.status ~= "D" then
    new_content = utils.read_file(change.repo .. "/" .. change.path)
  end

  return M.compute_diff(old_content, new_content)
end

-- on_close is called when the user exits the diff view (optional)
function M.open_split_diff(config, change, checkpoint_label, on_close)
  local old_content = nil
  local new_content = nil
  local filename = change.path

  -- Get old content from checkpoint
  if change.old_hash then
    old_content = snapshot.get_file_at_checkpoint(
      config,
      change.checkpoint_id,
      change.repo,
      change.path
    )
  end

  -- Get new content from disk (or from a second checkpoint for between-checkpoint diffs)
  if change.new_checkpoint_id then
    new_content = snapshot.get_file_at_checkpoint(
      config,
      change.new_checkpoint_id,
      change.repo,
      change.path
    )
  elseif change.status ~= "D" then
    new_content = utils.read_file(change.repo .. "/" .. change.path)
  end

  local ft = utils.get_filetype(filename)

  -- Close any existing iterview diff buffers
  M.close_diff_buffers()

  -- Create the left (old) buffer
  local old_buf = vim.api.nvim_create_buf(false, true)
  local buf_name = "iterview://" .. (checkpoint_label or "checkpoint") .. "/" .. filename
  -- Ensure unique buffer name
  pcall(vim.api.nvim_buf_set_name, old_buf, buf_name)

  if old_content then
    local lines = vim.split(old_content, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(old_buf, 0, -1, false, lines)
  else
    -- File didn't exist at checkpoint
    vim.api.nvim_buf_set_lines(old_buf, 0, -1, false, { "" })
    vim.api.nvim_buf_set_var(old_buf, "iterview_empty", true)
  end

  vim.bo[old_buf].buftype = "nofile"
  vim.bo[old_buf].bufhidden = "wipe"
  vim.bo[old_buf].modifiable = false
  vim.bo[old_buf].swapfile = false
  if ft ~= "" then
    vim.bo[old_buf].filetype = ft
  end
  vim.api.nvim_buf_set_var(old_buf, "iterview_diff_buf", true)

  if change.status == "D" then
    -- Deleted file: open old content on the left, empty on the right
    local new_buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, new_buf, "iterview://current/" .. filename .. " (deleted)")
    vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, { "" })
    vim.bo[new_buf].buftype = "nofile"
    vim.bo[new_buf].bufhidden = "wipe"
    vim.bo[new_buf].modifiable = false
    vim.bo[new_buf].swapfile = false
    if ft ~= "" then
      vim.bo[new_buf].filetype = ft
    end
    vim.api.nvim_buf_set_var(new_buf, "iterview_diff_buf", true)

    -- Open the split
    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(old_buf)
    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(new_buf)
    vim.cmd("diffthis")
  elseif change.new_checkpoint_id then
    -- Between-checkpoint diff: both sides are read-only
    local new_buf = vim.api.nvim_create_buf(false, true)
    local new_buf_name = "iterview://checkpoint-" .. change.new_checkpoint_id .. "/" .. filename
    pcall(vim.api.nvim_buf_set_name, new_buf, new_buf_name)

    if new_content then
      local lines = vim.split(new_content, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, { "" })
    end
    vim.bo[new_buf].buftype = "nofile"
    vim.bo[new_buf].bufhidden = "wipe"
    vim.bo[new_buf].modifiable = false
    vim.bo[new_buf].swapfile = false
    if ft ~= "" then
      vim.bo[new_buf].filetype = ft
    end
    vim.api.nvim_buf_set_var(new_buf, "iterview_diff_buf", true)

    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(old_buf)
    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(new_buf)
    vim.cmd("diffthis")
  else
    -- Normal case: old on left, real file on right (editable)
    local full_path = change.repo .. "/" .. change.path

    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(old_buf)
    vim.cmd("diffthis")
    vim.cmd("vsplit " .. vim.fn.fnameescape(full_path))
    vim.cmd("diffthis")
  end

  -- Set diff options
  vim.opt_local.diffopt:append("algorithm:patience")
  if vim.fn.has("nvim-0.9") == 1 then
    vim.opt_local.diffopt:append("linematch:60")
  end

  -- Set up keymaps for the diff tab (both windows)
  local diff_tab = vim.api.nvim_get_current_tabpage()
  local diff_wins = vim.api.nvim_tabpage_list_wins(diff_tab)

  local function close_diff()
    if vim.api.nvim_tabpage_is_valid(diff_tab)
      and vim.api.nvim_get_current_tabpage() == diff_tab then
      vim.cmd("tabclose")
    end
    if on_close then
      vim.schedule(on_close)
    end
  end

  for _, win in ipairs(diff_wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "q", close_diff, { buffer = buf, desc = "Close iterview diff" })
    vim.keymap.set("n", "<Esc>", close_diff, { buffer = buf, desc = "Close iterview diff" })
  end
end

function M.close_diff_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, is_diff = pcall(vim.api.nvim_buf_get_var, buf, "iterview_diff_buf")
    if ok and is_diff then
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end
end

return M
