local utils = require("iterview.utils")
local snapshot = require("iterview.snapshot")
local diff_mod = require("iterview.diff")

local M = {}

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local status_labels = {
  M = "[modified]",
  A = "[added]",
  D = "[deleted]",
  R = "[renamed]",
}

local status_hl = {
  M = "DiagnosticWarn",
  A = "DiagnosticOk",
  D = "DiagnosticError",
  R = "DiagnosticInfo",
}

local function format_stat(insertions, deletions)
  local parts = {}
  if insertions > 0 then
    table.insert(parts, "+" .. insertions)
  end
  if deletions > 0 then
    table.insert(parts, "-" .. deletions)
  end
  return table.concat(parts, " ")
end

local function make_diff_previewer(config, checkpoint_id, from_checkpoint_id)
  return previewers.new_buffer_previewer({
    title = "Diff Preview",
    define_preview = function(self, entry)
      local change = entry.value
      local old_content = nil
      local new_content = nil

      if change.old_hash then
        local source_id = from_checkpoint_id or checkpoint_id
        old_content = snapshot.get_file_at_checkpoint(
          config,
          source_id,
          change.repo,
          change.path
        )
      end

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

      local result = diff_mod.compute_diff(old_content, new_content)

      if result.diff == "" then
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "No differences" })
        return
      end

      local lines = vim.split(result.diff, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "diff"
    end,
  })
end

function M.diff_picker(config, checkpoint_id, opts)
  opts = opts or {}

  local checkpoint = snapshot.get_checkpoint(config, checkpoint_id)
  if not checkpoint then
    utils.error("checkpoint #" .. checkpoint_id .. " not found")
    return
  end

  local changes
  if opts.to_checkpoint_id then
    changes = snapshot.get_changes_between(config, checkpoint_id, opts.to_checkpoint_id)
  else
    changes = snapshot.get_changes(config, checkpoint_id)
  end

  if not changes or #changes == 0 then
    utils.notify("no changes since checkpoint #" .. checkpoint_id)
    return
  end

  -- Enrich changes with checkpoint_id for the diff module
  for _, change in ipairs(changes) do
    change.checkpoint_id = checkpoint_id
    if opts.to_checkpoint_id then
      change.new_checkpoint_id = opts.to_checkpoint_id
    end
  end

  -- Compute stats for each change
  local total_insertions = 0
  local total_deletions = 0

  for _, change in ipairs(changes) do
    local old_content = nil
    local new_content = nil

    if change.old_hash then
      old_content = snapshot.get_file_at_checkpoint(config, checkpoint_id, change.repo, change.path)
    end
    if change.new_checkpoint_id then
      new_content = snapshot.get_file_at_checkpoint(config, change.new_checkpoint_id, change.repo, change.path)
    elseif change.status ~= "D" then
      new_content = utils.read_file(change.repo .. "/" .. change.path)
    end

    local stats = diff_mod.compute_diff(old_content, new_content)
    change.insertions = stats.insertions
    change.deletions = stats.deletions
    total_insertions = total_insertions + stats.insertions
    total_deletions = total_deletions + stats.deletions
  end

  -- Determine if we need to show repo prefix (multi-repo scenario)
  local repos = {}
  for _, change in ipairs(changes) do
    repos[change.repo] = true
  end
  local multi_repo = vim.tbl_count(repos) > 1
  local cwd = vim.fn.getcwd()

  -- Pre-compute display paths and find the longest one for alignment
  local max_path_len = 0
  local max_stat_len = 0
  for _, change in ipairs(changes) do
    local path = change.path
    if multi_repo then
      path = utils.relative_path(change.repo, cwd) .. "/" .. path
    end
    change._display_path = path
    if #path > max_path_len then
      max_path_len = #path
    end
    local stat = format_stat(change.insertions or 0, change.deletions or 0)
    change._display_stat = stat
    if #stat > max_stat_len then
      max_stat_len = #stat
    end
  end

  local label_width = 12
  local stat_width = math.max(max_stat_len, 8)

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = label_width },
      { width = max_path_len + 4 },
      { width = stat_width },
    },
  })

  local function make_display(entry)
    local change = entry.value
    local label = status_labels[change.status] or "[unknown]"
    local hl = status_hl[change.status] or "Normal"

    return displayer({
      { label, hl },
      { change._display_path },
      { change._display_stat, "Comment" },
    })
  end

  local title = "Iterview: Changes since #" .. checkpoint_id
  if opts.to_checkpoint_id then
    title = "Iterview: Changes #" .. checkpoint_id .. " -> #" .. opts.to_checkpoint_id
  end

  local summary = #changes .. " files changed"
  if total_insertions > 0 then
    summary = summary .. ", " .. total_insertions .. " insertions(+)"
  end
  if total_deletions > 0 then
    summary = summary .. ", " .. total_deletions .. " deletions(-)"
  end

  local telescope_opts = config.telescope or {}

  pickers.new({
    layout_strategy = telescope_opts.layout_strategy or "vertical",
    layout_config = telescope_opts.layout_config or {
      height = 0.95,
      width = 0.8,
      preview_height = 0.6,
    },
  }, {
    prompt_title = title,
    results_title = summary,
    finder = finders.new_table({
      results = changes,
      entry_maker = function(change)
        local path = change.path
        if multi_repo then
          path = utils.relative_path(change.repo, cwd) .. "/" .. path
        end
        return {
          value = change,
          display = make_display,
          ordinal = change.status .. " " .. path,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = make_diff_previewer(config, checkpoint_id),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        if not entry then return end

        -- Close the picker
        actions.close(prompt_bufnr)

        local change = entry.value
        local label = "checkpoint #" .. checkpoint_id

        -- Open the diff, and when it closes, reopen the picker
        diff_mod.open_split_diff(config, change, label, function()
          M.diff_picker(config, checkpoint_id, opts)
        end)
      end)

      -- Ctrl+o: jump directly to the file
      local function open_file()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local change = entry.value
        if change.status == "D" then
          utils.notify("file was deleted", vim.log.levels.WARN)
          return
        end
        actions.close(prompt_bufnr)
        vim.cmd("edit " .. vim.fn.fnameescape(change.repo .. "/" .. change.path))
      end

      map("i", "<C-o>", open_file)
      map("n", "<C-o>", open_file)

      return true
    end,
  }):find()
end

function M.history_picker(config)
  local checkpoints = snapshot.list_checkpoints(config)

  if #checkpoints == 0 then
    utils.notify("no checkpoints yet. Use <Space>ic to create one.")
    return
  end

  -- Pre-compute change counts for each checkpoint
  for _, cp in ipairs(checkpoints) do
    local changes = snapshot.get_changes(config, cp.id)
    cp.change_count = changes and #changes or 0
  end

  local function make_preview(self, entry)
    local cp = entry.value
    local changes = snapshot.get_changes(config, cp.id)

    local lines = {
      "Checkpoint #" .. cp.id,
      "Created: " .. cp.timestamp,
      "",
    }

    if not changes or #changes == 0 then
      table.insert(lines, "No changes since this checkpoint")
    else
      table.insert(lines, "Files changed after this checkpoint:")
      table.insert(lines, "")
      for _, change in ipairs(changes) do
        local icon = status_icons[change.status] or "?"
        local path = change.path

        -- Compute stats inline
        local old_content = nil
        local new_content = nil
        if change.old_hash then
          old_content = snapshot.get_file_at_checkpoint(config, cp.id, change.repo, change.path)
        end
        if change.status ~= "D" then
          new_content = utils.read_file(change.repo .. "/" .. change.path)
        end
        local stats = diff_mod.compute_diff(old_content, new_content)
        local stat = format_stat(stats.insertions, stats.deletions)

        local line = "  " .. icon .. " " .. path
        if stat ~= "" then
          line = line .. "  " .. stat
        end
        table.insert(lines, line)
      end
    end

    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
  end

  local selected_checkpoints = {}

  local telescope_opts = config.telescope or {}

  pickers.new({
    layout_strategy = telescope_opts.layout_strategy or "vertical",
    layout_config = telescope_opts.layout_config or {
      height = 0.95,
      width = 0.8,
      preview_height = 0.6,
    },
  }, {
    prompt_title = "Iterview: Checkpoint History",
    finder = finders.new_table({
      results = checkpoints,
      entry_maker = function(cp)
        local label = "#" .. cp.id .. "  " .. cp.timestamp
        if cp.change_count > 0 then
          label = label .. "  (" .. cp.change_count .. " files changed after)"
        else
          label = label .. "  (no changes)"
        end

        return {
          value = cp,
          display = label,
          ordinal = tostring(cp.id) .. " " .. cp.timestamp,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Checkpoint Details",
      define_preview = make_preview,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- Tab to select checkpoints for between-checkpoint diff
      map("i", "<Tab>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local cp_id = entry.value.id
          if selected_checkpoints[cp_id] then
            selected_checkpoints[cp_id] = nil
          else
            selected_checkpoints[cp_id] = true
          end
        end
        -- Move to next
        actions.move_selection_next(prompt_bufnr)
      end)

      map("n", "<Tab>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local cp_id = entry.value.id
          if selected_checkpoints[cp_id] then
            selected_checkpoints[cp_id] = nil
          else
            selected_checkpoints[cp_id] = true
          end
        end
        actions.move_selection_next(prompt_bufnr)
      end)

      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)

        if not entry then return end

        -- Check if two checkpoints were selected with Tab
        local tab_selected = vim.tbl_keys(selected_checkpoints)
        if #tab_selected == 2 then
          table.sort(tab_selected)
          M.diff_picker(config, tab_selected[1], {
            to_checkpoint_id = tab_selected[2],
          })
        else
          -- Open diff picker for the selected checkpoint
          M.diff_picker(config, entry.value.id)
        end
      end)

      return true
    end,
  }):find()
end

return M
