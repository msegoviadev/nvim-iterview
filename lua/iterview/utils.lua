local M = {}

function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  vim.notify("iterview: " .. msg, level)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.run_cmd(cmd)
  local result = vim.fn.systemlist(cmd, nil)
  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    return nil, table.concat(result, "\n")
  end
  return result
end

function M.run_git(args, repo_path)
  local cmd = { "git" }
  if repo_path then
    vim.list_extend(cmd, { "-C", repo_path })
  end
  vim.list_extend(cmd, args)
  return M.run_cmd(cmd)
end

function M.build_git_cmd(args, repo_path)
  local cmd = { "git" }
  if repo_path then
    vim.list_extend(cmd, { "-C", repo_path })
  end
  vim.list_extend(cmd, args)
  return cmd
end

function M.run_git_with_stdin(args, repo_path, stdin_data, callback)
  local cmd = M.build_git_cmd(args, repo_path)
  vim.system(cmd, { stdin = stdin_data }, function(result)
    if result.code ~= 0 then
      callback(nil, result.stderr or "git command failed")
      return
    end
    local lines = {}
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end
    callback(lines)
  end)
end

function M.run_git_with_stdin_sync(args, repo_path, stdin_data)
  local cmd = M.build_git_cmd(args, repo_path)
  local result = vim.system(cmd, { stdin = stdin_data }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or "git command failed"
  end
  local lines = {}
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

function M.file_exists(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil
end

function M.read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil
  end
  local content = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return content
end

function M.write_file(path, content)
  local fd = vim.uv.fs_open(path, "w", 438)
  if not fd then
    return false
  end
  vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  return true
end

function M.ensure_dir(path)
  if not M.file_exists(path) then
    vim.fn.mkdir(path, "p")
  end
end

function M.get_filetype(filename)
  local ext = filename:match("%.([^%.]+)$")
  if not ext then
    return ""
  end
  local ft = vim.filetype.match({ filename = filename })
  return ft or ""
end

function M.relative_path(filepath, base)
  if filepath:sub(1, #base) == base then
    local rel = filepath:sub(#base + 1)
    if rel:sub(1, 1) == "/" then
      rel = rel:sub(2)
    end
    return rel
  end
  return filepath
end

return M
