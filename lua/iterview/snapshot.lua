local utils = require("iterview.utils")

local M = {}

local _repo_cache = nil

function M.discover_repos(cwd, config)
  if _repo_cache then
    return _repo_cache
  end

  local max_depth = config.git_search_depth or 4
  local exclude_dirs = config.exclude_dirs or {}

  local cmd = { "fd", "-H", "--glob", ".git", "-t", "d", "--max-depth", tostring(max_depth) }
  for _, dir in ipairs(exclude_dirs) do
    -- Never exclude .git itself since that's what we're searching for
    if dir ~= ".git" then
      vim.list_extend(cmd, { "--exclude", dir })
    end
  end
  table.insert(cmd, cwd)

  local result, err = utils.run_cmd(cmd)
  if not result then
    -- Fallback: check if cwd itself is a git repo
    local toplevel = utils.run_git({ "rev-parse", "--show-toplevel" }, cwd)
    if toplevel and #toplevel > 0 then
      _repo_cache = { toplevel[1] }
      return _repo_cache
    end
    utils.error("no git repositories found under " .. cwd)
    return {}
  end

  local repos = {}
  for _, git_dir in ipairs(result) do
    if git_dir ~= "" then
      -- Strip trailing /.git/ or /.git to get repo root
      local repo_root = git_dir:gsub("/.git/?$", "")
      table.insert(repos, repo_root)
    end
  end

  if #repos == 0 then
    -- Fallback: check if cwd itself is a git repo
    local toplevel = utils.run_git({ "rev-parse", "--show-toplevel" }, cwd)
    if toplevel and #toplevel > 0 then
      repos = { toplevel[1] }
    end
  end

  _repo_cache = repos
  return repos
end

function M.invalidate_cache()
  _repo_cache = nil
end

local function get_repo_files(repo_path)
  -- Get both tracked and untracked files
  local tracked = utils.run_git({ "ls-files" }, repo_path) or {}
  local untracked = utils.run_git({ "ls-files", "--others", "--exclude-standard" }, repo_path) or {}

  local files = {}
  local seen = {}
  for _, f in ipairs(tracked) do
    if f ~= "" and not seen[f] then
      seen[f] = true
      table.insert(files, f)
    end
  end
  for _, f in ipairs(untracked) do
    if f ~= "" and not seen[f] then
      seen[f] = true
      table.insert(files, f)
    end
  end
  return files
end

-- Batch hash files using git hash-object --stdin-paths (async)
-- callback receives (hash_map, err) where hash_map is { filepath = hash }
local function hash_files_batch_async(repo_path, filepaths, write, callback)
  if #filepaths == 0 then
    callback({})
    return
  end

  local args = { "hash-object", "--stdin-paths" }
  if write then
    table.insert(args, 2, "-w")
  end

  local stdin = table.concat(filepaths, "\n") .. "\n"
  utils.run_git_with_stdin(args, repo_path, stdin, function(hashes, err)
    if err or not hashes then
      callback(nil, err or "hash-object failed")
      return
    end

    local result = {}
    for i, filepath in ipairs(filepaths) do
      if hashes[i] then
        result[filepath] = hashes[i]
      end
    end
    callback(result)
  end)
end

-- Batch hash files using git hash-object --stdin-paths (synchronous)
-- Returns hash_map { filepath = hash } or nil, err
local function hash_files_batch_sync(repo_path, filepaths, write)
  if #filepaths == 0 then
    return {}
  end

  local args = { "hash-object", "--stdin-paths" }
  if write then
    table.insert(args, 2, "-w")
  end

  local stdin = table.concat(filepaths, "\n") .. "\n"
  local hashes, err = utils.run_git_with_stdin_sync(args, repo_path, stdin)
  if not hashes then
    return nil, err
  end

  local result = {}
  for i, filepath in ipairs(filepaths) do
    if hashes[i] then
      result[filepath] = hashes[i]
    end
  end
  return result
end

function M.get_storage_dir(config)
  local cwd = vim.fn.getcwd()
  return cwd .. "/" .. (config.storage_dir or ".iterview")
end

function M.get_manifests_dir(config)
  return M.get_storage_dir(config) .. "/manifests"
end

function M.get_next_checkpoint_id(config)
  local manifests_dir = M.get_manifests_dir(config)
  utils.ensure_dir(manifests_dir)

  local max_id = 0
  local handle = vim.uv.fs_scandir(manifests_dir)
  if handle then
    while true do
      local name, type = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if type == "file" then
        local id = tonumber(name:match("^checkpoint%-(%d+)%.json$"))
        if id and id > max_id then
          max_id = id
        end
      end
    end
  end
  return max_id + 1
end

-- Async checkpoint creation
-- callback receives (checkpoint_id, total_files) on success, or nil on error
function M.create_checkpoint(config, callback)
  local cwd = vim.fn.getcwd()
  local repos = M.discover_repos(cwd, config)

  if #repos == 0 then
    utils.error("no git repositories found")
    if callback then callback(nil) end
    return
  end

  local checkpoint_id = M.get_next_checkpoint_id(config)
  local manifests_dir = M.get_manifests_dir(config)
  utils.ensure_dir(manifests_dir)

  local manifest = {
    id = checkpoint_id,
    timestamp = os.date("%Y-%m-%dT%H:%M:%S"),
    cwd = cwd,
    repos = {},
  }

  -- Collect all repo file lists synchronously (fast, one git call per repo)
  local repo_file_lists = {}
  for _, repo_path in ipairs(repos) do
    local files = get_repo_files(repo_path)
    -- Filter to only files that actually exist on disk
    local existing = {}
    for _, filepath in ipairs(files) do
      local full_path = repo_path .. "/" .. filepath
      if utils.file_exists(full_path) then
        table.insert(existing, filepath)
      end
    end
    repo_file_lists[repo_path] = existing
  end

  -- Hash all repos asynchronously, track completion
  local pending = #repos
  local total_files = 0

  for _, repo_path in ipairs(repos) do
    local filepaths = repo_file_lists[repo_path]

    hash_files_batch_async(repo_path, filepaths, true, function(hash_map, err)
      if err then
        vim.schedule(function()
          utils.error("failed to hash files in " .. repo_path .. ": " .. tostring(err))
        end)
        hash_map = {}
      end

      local file_entries = {}
      for filepath, hash in pairs(hash_map or {}) do
        file_entries[filepath] = { hash = hash }
        total_files = total_files + 1
      end
      manifest.repos[repo_path] = { files = file_entries }

      pending = pending - 1
      if pending == 0 then
        -- All repos done, write manifest (must schedule back to main thread)
        vim.schedule(function()
          local json = vim.fn.json_encode(manifest)
          local manifest_path = manifests_dir .. "/checkpoint-" .. checkpoint_id .. ".json"
          utils.write_file(manifest_path, json)

          if config.auto_gitignore then
            M.ensure_gitignored(config)
          end

          M.prune_checkpoints(config)

          if callback then
            callback(checkpoint_id, total_files)
          end
        end)
      end
    end)
  end
end

function M.ensure_gitignored(config)
  local storage_dir = config.storage_dir or ".iterview"
  local cwd = vim.fn.getcwd()
  local repos = M.discover_repos(cwd, config)

  for _, repo_path in ipairs(repos) do
    local gitignore_path = repo_path .. "/.gitignore"
    local content = utils.read_file(gitignore_path) or ""
    local pattern = storage_dir

    -- Check if already in gitignore
    for line in content:gmatch("[^\r\n]+") do
      if line == pattern or line == pattern .. "/" then
        return
      end
    end

    -- Only add to gitignore if .iterview dir is under this repo
    local storage_full = M.get_storage_dir(config)
    if storage_full:sub(1, #repo_path) == repo_path then
      local suffix = content:sub(-1) == "\n" and "" or "\n"
      content = content .. suffix .. pattern .. "/\n"
      utils.write_file(gitignore_path, content)
    end
  end
end

function M.prune_checkpoints(config)
  local max = config.max_checkpoints or 20
  local manifests_dir = M.get_manifests_dir(config)

  local checkpoints = M.list_checkpoints(config)
  if #checkpoints <= max then
    return
  end

  -- Sort by id ascending, remove oldest
  table.sort(checkpoints, function(a, b) return a.id < b.id end)
  local to_remove = #checkpoints - max
  for i = 1, to_remove do
    local path = manifests_dir .. "/checkpoint-" .. checkpoints[i].id .. ".json"
    vim.uv.fs_unlink(path)
  end
end

function M.list_checkpoints(config)
  local manifests_dir = M.get_manifests_dir(config)
  utils.ensure_dir(manifests_dir)

  local checkpoints = {}
  local handle = vim.uv.fs_scandir(manifests_dir)
  if not handle then
    return checkpoints
  end

  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if type == "file" and name:match("^checkpoint%-%d+%.json$") then
      local content = utils.read_file(manifests_dir .. "/" .. name)
      if content then
        local ok, manifest = pcall(vim.fn.json_decode, content)
        if ok and manifest then
          table.insert(checkpoints, manifest)
        end
      end
    end
  end

  -- Sort by id descending (newest first)
  table.sort(checkpoints, function(a, b) return a.id > b.id end)
  return checkpoints
end

function M.get_latest_checkpoint(config)
  local checkpoints = M.list_checkpoints(config)
  if #checkpoints == 0 then
    return nil
  end
  return checkpoints[1]
end

function M.get_checkpoint(config, checkpoint_id)
  local manifests_dir = M.get_manifests_dir(config)
  local path = manifests_dir .. "/checkpoint-" .. checkpoint_id .. ".json"
  local content = utils.read_file(path)
  if not content then
    return nil
  end
  local ok, manifest = pcall(vim.fn.json_decode, content)
  if not ok then
    return nil
  end
  return manifest
end

function M.get_changes(config, checkpoint_id)
  local checkpoint = M.get_checkpoint(config, checkpoint_id)
  if not checkpoint then
    return nil
  end

  local changes = {}

  for repo_path, repo_data in pairs(checkpoint.repos) do
    local old_files = repo_data.files or {}

    -- Get current files
    local current_files = get_repo_files(repo_path)
    local current_set = {}
    for _, f in ipairs(current_files) do
      current_set[f] = true
    end

    -- Collect all files we need to hash (existing files from old snapshot)
    local files_to_hash = {}
    for filepath, _ in pairs(old_files) do
      local full_path = repo_path .. "/" .. filepath
      if utils.file_exists(full_path) then
        table.insert(files_to_hash, filepath)
      end
    end

    -- Also collect new files that need hashing
    local new_files = {}
    for _, filepath in ipairs(current_files) do
      if not old_files[filepath] then
        local full_path = repo_path .. "/" .. filepath
        if utils.file_exists(full_path) then
          table.insert(new_files, filepath)
          table.insert(files_to_hash, filepath)
        end
      end
    end

    -- Batch hash all files in one git call (synchronous, fast with batching)
    local current_hashes = hash_files_batch_sync(repo_path, files_to_hash, false) or {}

    -- Check for modified and deleted files
    for filepath, file_data in pairs(old_files) do
      local full_path = repo_path .. "/" .. filepath
      if not utils.file_exists(full_path) then
        table.insert(changes, {
          path = filepath,
          repo = repo_path,
          status = "D",
          old_hash = file_data.hash,
          new_hash = nil,
        })
      else
        local current_hash = current_hashes[filepath]
        if current_hash and current_hash ~= file_data.hash then
          table.insert(changes, {
            path = filepath,
            repo = repo_path,
            status = "M",
            old_hash = file_data.hash,
            new_hash = current_hash,
          })
        end
      end
    end

    -- Check for added files
    for _, filepath in ipairs(new_files) do
      table.insert(changes, {
        path = filepath,
        repo = repo_path,
        status = "A",
        old_hash = nil,
        new_hash = current_hashes[filepath],
      })
    end
  end

  -- Check for repos that exist now but weren't in the checkpoint
  local cwd = vim.fn.getcwd()
  local current_repos = M.discover_repos(cwd, config)
  for _, repo_path in ipairs(current_repos) do
    if not checkpoint.repos[repo_path] then
      local files = get_repo_files(repo_path)
      local existing = {}
      for _, filepath in ipairs(files) do
        local full_path = repo_path .. "/" .. filepath
        if utils.file_exists(full_path) then
          table.insert(existing, filepath)
        end
      end

      local hashes = hash_files_batch_sync(repo_path, existing, false) or {}
      for _, filepath in ipairs(existing) do
        table.insert(changes, {
          path = filepath,
          repo = repo_path,
          status = "A",
          old_hash = nil,
          new_hash = hashes[filepath],
        })
      end
    end
  end

  -- Sort: modified first, then added, then deleted. Within each group, alphabetical.
  local status_order = { M = 1, A = 2, D = 3 }
  table.sort(changes, function(a, b)
    local oa = status_order[a.status] or 9
    local ob = status_order[b.status] or 9
    if oa ~= ob then return oa < ob end
    return a.path < b.path
  end)

  return changes
end

function M.get_file_at_checkpoint(config, checkpoint_id, repo_path, filepath)
  local checkpoint = M.get_checkpoint(config, checkpoint_id)
  if not checkpoint then
    return nil
  end

  local repo_data = checkpoint.repos[repo_path]
  if not repo_data then
    return nil
  end

  local file_data = repo_data.files[filepath]
  if not file_data then
    return nil
  end

  local result = utils.run_git({ "cat-file", "-p", file_data.hash }, repo_path)
  if result then
    return table.concat(result, "\n")
  end
  return nil
end

function M.get_changes_between(config, from_id, to_id)
  local from_checkpoint = M.get_checkpoint(config, from_id)
  local to_checkpoint = M.get_checkpoint(config, to_id)
  if not from_checkpoint or not to_checkpoint then
    return nil
  end

  local changes = {}

  -- Collect all repos from both checkpoints
  local all_repos = {}
  for repo_path in pairs(from_checkpoint.repos) do
    all_repos[repo_path] = true
  end
  for repo_path in pairs(to_checkpoint.repos) do
    all_repos[repo_path] = true
  end

  for repo_path in pairs(all_repos) do
    local from_files = (from_checkpoint.repos[repo_path] or {}).files or {}
    local to_files = (to_checkpoint.repos[repo_path] or {}).files or {}

    -- Check for modified and deleted files (in from, check against to)
    for filepath, from_data in pairs(from_files) do
      local to_data = to_files[filepath]
      if not to_data then
        table.insert(changes, {
          path = filepath,
          repo = repo_path,
          status = "D",
          old_hash = from_data.hash,
          new_hash = nil,
        })
      elseif to_data.hash ~= from_data.hash then
        table.insert(changes, {
          path = filepath,
          repo = repo_path,
          status = "M",
          old_hash = from_data.hash,
          new_hash = to_data.hash,
        })
      end
    end

    -- Check for added files (in to but not in from)
    for filepath, to_data in pairs(to_files) do
      if not from_files[filepath] then
        table.insert(changes, {
          path = filepath,
          repo = repo_path,
          status = "A",
          old_hash = nil,
          new_hash = to_data.hash,
        })
      end
    end
  end

  local status_order = { M = 1, A = 2, D = 3 }
  table.sort(changes, function(a, b)
    local oa = status_order[a.status] or 9
    local ob = status_order[b.status] or 9
    if oa ~= ob then return oa < ob end
    return a.path < b.path
  end)

  return changes
end

function M.clear_checkpoints(config)
  local manifests_dir = M.get_manifests_dir(config)
  local handle = vim.uv.fs_scandir(manifests_dir)
  if not handle then
    return 0
  end

  local count = 0
  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if type == "file" and name:match("^checkpoint%-%d+%.json$") then
      vim.uv.fs_unlink(manifests_dir .. "/" .. name)
      count = count + 1
    end
  end
  return count
end

return M
