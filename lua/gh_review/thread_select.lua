-- Repository-wide review-thread picker and cross-file navigation.

local state = require("gh_review.state")

local M = {}
local picker_bufnr = -1
local picker_winid = -1

local function thread_line(thread)
  local line = state.get(thread, "line", nil)
  if type(line) == "number" and line > 0 then return line end
  return state.get(thread, "originalLine", 0)
end

local function close_picker()
  local winid = picker_winid
  local bufnr = picker_bufnr
  picker_winid = -1
  picker_bufnr = -1
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function is_pending(thread)
  local comments = state.get(state.get(thread, "comments", {}), "nodes", {})
  for _, comment in ipairs(comments) do
    local review = state.get(comment, "pullRequestReview", {})
    if state.get(review, "state", "") == "PENDING" then return true end
  end
  return false
end

local function status(thread)
  local labels = {}
  if is_pending(thread) then labels[#labels + 1] = "pending" end
  if state.get(thread, "isResolved", false) then labels[#labels + 1] = "resolved" end
  if state.get(thread, "isOutdated", false) then labels[#labels + 1] = "outdated" end
  if #labels == 0 then labels[1] = "active" end
  return "[" .. table.concat(labels, ",") .. "]"
end

local function comment_preview(thread)
  local comments = state.get(state.get(thread, "comments", {}), "nodes", {})
  local first = comments[1] or {}
  local author = state.get(state.get(first, "author", {}), "login", "unknown")
  local body = state.get(first, "body", ""):gsub("\r", ""):gsub("\n", " "):gsub("%s+", " ")
  if #body > 60 then body = body:sub(1, 57) .. "..." end
  return author .. ": " .. body
end

local function format_thread(thread)
  return string.format("%-21s  %-5s  %s:%d  %s",
    status(thread), state.get(thread, "diffSide", "RIGHT"),
    state.get(thread, "path", "unknown"), thread_line(thread), comment_preview(thread))
end

local function sorted_threads()
  local threads = {}
  for _, thread in pairs(state.get_threads()) do threads[#threads + 1] = thread end
  -- GraphQL ordering should not determine picker movement. Grouping by file and
  -- line makes repeated invocations predictable and mirrors walking a diff.
  table.sort(threads, function(left, right)
    local left_path = state.get(left, "path", "")
    local right_path = state.get(right, "path", "")
    if left_path ~= right_path then return left_path < right_path end
    local left_line = thread_line(left)
    local right_line = thread_line(right)
    if left_line ~= right_line then return left_line < right_line end
    local left_side = state.get(left, "diffSide", "RIGHT")
    local right_side = state.get(right, "diffSide", "RIGHT")
    if left_side ~= right_side then return left_side < right_side end
    return state.get(left, "id", "") < state.get(right, "id", "")
  end)
  return threads
end

local function navigate_to_thread(thread)
  local path = state.get(thread, "path", "")
  local side = state.get(thread, "diffSide", "RIGHT")
  local line = thread_line(thread)
  -- diff.open calls back only after both sides are rendered. Position the
  -- correct side first so closing the thread pane returns to its source line.
  require("gh_review.diff").open(path, function(left_bufnr, right_bufnr)
    local bufnr = side == "LEFT" and left_bufnr or right_bufnr
    local winid = bufnr and vim.fn.bufwinid(bufnr) or -1
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(line, line_count)), 0 })
    end
    require("gh_review.thread").open(state.get(thread, "id", ""))
  end)
end

local function export_to_quickfix(threads)
  if #threads == 0 then
    vim.notify("[gh-review] No threads in the current filter", vim.log.levels.WARN)
    return
  end
  if not state.is_local_checkout() then
    -- :cfile creates ordinary file entries. In a remote review those paths
    -- would resolve to unrelated working-tree content rather than the PR head.
    vim.notify("[gh-review] Quickfix thread export requires a checked-out PR", vim.log.levels.ERROR)
    return
  end

  local root = vim.fs.root(vim.fn.getcwd(), ".git")
  if not root then
    vim.notify("[gh-review] Could not find the repository root for quickfix", vim.log.levels.ERROR)
    return
  end

  local entries = {}
  for _, thread in ipairs(threads) do
    local path = root .. "/" .. state.get(thread, "path", "")
    entries[#entries + 1] = string.format("%s:%d:1: %s %s", path,
      math.max(1, thread_line(thread)), status(thread), comment_preview(thread))
  end

  -- :cfile is intentionally the parser of record. The temporary file is only
  -- transport: once quickfix owns the parsed entries it can be removed without
  -- affecting navigation or the quickfix window.
  local errorfile = vim.fn.tempname() .. "-gh-review-threads"
  if vim.fn.writefile(entries, errorfile) ~= 0 then
    vim.notify("[gh-review] Could not write the quickfix thread list", vim.log.levels.ERROR)
    return
  end
  local ok, err = pcall(vim.cmd, "silent cfile " .. vim.fn.fnameescape(errorfile))
  vim.fn.delete(errorfile)
  if not ok then
    vim.notify("[gh-review] Could not load thread quickfix: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  close_picker()
  vim.cmd("copen")
end

function M.open()
  if state.get_pr_id() == "" then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end

  local all_threads = sorted_threads()
  if #all_threads == 0 then
    vim.notify("[gh-review] No review threads found")
    return
  end

  close_picker()
  local lines = {}
  local max_width = vim.fn.strdisplaywidth("Threads [all] · a/u/p · c quickfix")
  for _, thread in ipairs(all_threads) do
    local line = format_thread(thread)
    lines[#lines + 1] = line
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  picker_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_bufnr].buftype = "nofile"
  vim.bo[picker_bufnr].bufhidden = "wipe"
  vim.bo[picker_bufnr].swapfile = false
  vim.bo[picker_bufnr].filetype = "gh-review-threads"
  vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, lines)
  vim.bo[picker_bufnr].modifiable = false

  local width = math.min(max_width, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  picker_winid = vim.api.nvim_open_win(picker_bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Threads [all] · a/u/p · c quickfix ",
    title_pos = "center",
  })
  vim.wo[picker_winid].cursorline = true
  vim.wo[picker_winid].wrap = false

  local visible_threads = all_threads
  local function apply_filter(name)
    visible_threads = {}
    for _, thread in ipairs(all_threads) do
      local include = name == "all"
        or (name == "unresolved" and not state.get(thread, "isResolved", false))
        or (name == "pending" and is_pending(thread))
      if include then visible_threads[#visible_threads + 1] = thread end
    end

    local filtered_lines = {}
    for _, thread in ipairs(visible_threads) do filtered_lines[#filtered_lines + 1] = format_thread(thread) end
    if #filtered_lines == 0 then filtered_lines[1] = "No " .. name .. " threads" end

    vim.bo[picker_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, filtered_lines)
    vim.bo[picker_bufnr].modifiable = false
    -- Keep the picker open when a filter is empty and expose the active filter
    -- in its title, making rapid a/u/p switching visible and reversible.
    vim.api.nvim_win_set_config(picker_winid, {
      height = math.min(#filtered_lines, math.max(1, vim.o.lines - 4)),
      title = string.format(" Threads [%s] · a/u/p · c quickfix ", name),
      title_pos = "center",
    })
    vim.api.nvim_win_set_cursor(picker_winid, { 1, 0 })
  end

  local function choose_current()
    local choice = visible_threads[vim.api.nvim_win_get_cursor(picker_winid)[1]]
    if not choice then return end
    close_picker()
    navigate_to_thread(choice)
  end
  local map_opts = { buffer = picker_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", choose_current, map_opts)
  vim.keymap.set("n", "a", function() apply_filter("all") end, map_opts)
  vim.keymap.set("n", "u", function() apply_filter("unresolved") end, map_opts)
  vim.keymap.set("n", "p", function() apply_filter("pending") end, map_opts)
  vim.keymap.set("n", "c", function() export_to_quickfix(visible_threads) end, map_opts)
  vim.keymap.set("n", "q", close_picker, map_opts)
  vim.keymap.set("n", "<Esc>", close_picker, map_opts)
  vim.keymap.set("n", "<C-c>", close_picker, map_opts)
end

return M
