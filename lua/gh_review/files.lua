-- Changed-files picker and sequential file-review navigation.

local state = require("gh_review.state")
local config = require("gh_review.config")

local M = {}
local BUF_NAME = "gh-review://files"

local function change_type_to_flag(change_type)
  if change_type == "ADDED" then return "A"
  elseif change_type == "DELETED" then return "D"
  elseif change_type == "RENAMED" then return "R"
  elseif change_type == "COPIED" then return "C"
  end
  return "M"
end

local function format_file(file)
  local path = state.get(file, "path", "")
  local thread_count = #state.get_threads_for_file(path)
  local thread_info = ""
  if thread_count > 0 then
    thread_info = string.format("  [%d thread%s]", thread_count, thread_count > 1 and "s" or "")
  end
  local checkbox = state.is_file_checked(path) and "[x]" or "[ ]"
  return string.format("%s +%-4d -%-4d %s  %s%s", checkbox,
    state.get(file, "additions", 0), state.get(file, "deletions", 0),
    change_type_to_flag(state.get(file, "changeType", "MODIFIED")), path, thread_info)
end

local function picker_title()
  local range = "Files"
  local diff_base = state.get_diff_base_oid()
  if diff_base ~= "" and diff_base ~= state.get_merge_base_oid() then
    range = "Files after " .. diff_base:sub(1, 8)
  end
  return string.format(" PR #%d · %s · %s (%d) ", state.get_pr_number(),
    state.get_pr_title(), range, #state.get_changed_files())
end

local function render()
  local bufnr = state.get_files_bufnr()
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local lines = {}
  local max_width = vim.fn.strdisplaywidth(picker_title())
  for _, file in ipairs(state.get_changed_files()) do
    local line = format_file(file)
    lines[#lines + 1] = line
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  if #lines == 0 then lines[1] = "No changed files" end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local height = math.min(#lines, math.max(1, vim.o.lines - 4))
    local width = math.min(max_width, math.max(1, vim.o.columns - 4))
    vim.api.nvim_win_set_config(winid, {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      title = picker_title(),
      title_pos = "center",
    })
    vim.api.nvim_win_set_cursor(winid, { math.min(cursor[1], #lines), 0 })
  end
end

-- Update local UI immediately, then reconcile with GitHub. The guarded revert
-- preserves a newer user action when an older request fails out of order.
function M.set_viewed(path, viewed)
  if path == "" or state.is_file_checked(path) == viewed then return end
  state.set_file_checked(path, viewed)
  M.rerender()

  local api = require("gh_review.api")
  local graphql = require("gh_review.graphql")
  local mutation = viewed and graphql.MUTATION_MARK_FILE_VIEWED or graphql.MUTATION_UNMARK_FILE_VIEWED
  api.graphql(mutation, { pullRequestId = state.get_pr_id(), path = path }, function(result, err)
    local data = ((result or {}).data) or {}
    local ok = not err and (data.markFileAsViewed or data.unmarkFileAsViewed)
    if not ok and state.is_file_checked(path) == viewed then
      state.set_file_checked(path, not viewed)
      M.rerender()
    end
  end)
end

local function file_under_cursor()
  local files = state.get_changed_files()
  return files[vim.fn.line(".")]
end

local function toggle_viewed_under_cursor()
  local file = file_under_cursor()
  if not file then return end
  local path = state.get(file, "path", "")
  M.set_viewed(path, not state.is_file_checked(path))
end

local function open_file_under_cursor()
  local file = file_under_cursor()
  if not file then return end
  local path = state.get(file, "path", "")
  M.close()
  require("gh_review.diff").open(path)
end

local function refresh_and_render()
  require("gh_review").refresh_threads()
end

-- Action declaration remains configuration-driven even though the surface is
-- now floating, preserving existing Lazy opts for the former files list.
local ACTIONS = {
  open          = { { "n", open_file_under_cursor,      "Open diff" } },
  toggle_viewed = { { "n", toggle_viewed_under_cursor, "Toggle file reviewed" } },
  refresh       = { { "n", refresh_and_render,          "Refresh threads" } },
  toggle_files  = { { "n", function() M.close() end,    "Close files picker" } },
  close         = { { "n", function() M.close() end,    "Close files picker" } },
}

function M.open()
  if state.get_pr_id() == "" then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end

  local existing = state.get_files_bufnr()
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    local winid = vim.fn.bufwinid(existing)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      render()
      return
    end
    vim.api.nvim_buf_delete(existing, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, BUF_NAME)
  state.set_files_bufnr(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "gh-review-files"

  local files = state.get_changed_files()
  local lines = {}
  local max_width = vim.fn.strdisplaywidth(picker_title())
  for _, file in ipairs(files) do
    local line = format_file(file)
    lines[#lines + 1] = line
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  if #lines == 0 then lines[1] = "No changed files" end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local width = math.min(max_width, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = picker_title(),
    title_pos = "center",
  })
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = false
  config.apply_keymaps(bufnr, "files", ACTIONS)
end

function M.close()
  local bufnr = state.get_files_bufnr()
  state.set_files_bufnr(-1)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
end

function M.toggle()
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.fn.bufwinid(bufnr) ~= -1 then
    M.close()
  else
    M.open()
  end
end

function M.rerender()
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.fn.bufwinid(bufnr) ~= -1 then render() end
end

-- Review files in exact PR order in either direction. Navigation deliberately
-- does not change GitHub's viewed state: opening a diff is not proof that the
-- reviewer finished it, so viewed state remains an explicit files-picker action.
-- Both commands share this path to keep validation and boundaries symmetric;
-- already-viewed destinations are intentionally not skipped.
local function move_file(offset)
  local path = state.get_diff_path()
  if path == "" then
    vim.notify("[gh-review] No review file is currently open", vim.log.levels.ERROR)
    return
  end

  local files = state.get_changed_files()
  local current_index
  for index, file in ipairs(files) do
    if state.get(file, "path", "") == path then current_index = index break end
  end
  if not current_index then
    vim.notify("[gh-review] Current file is not in the active review range", vim.log.levels.ERROR)
    return
  end

  local target_index = current_index + offset
  if target_index < 1 or target_index > #files then
    local boundary = offset < 0 and "first" or "final"
    vim.notify("[gh-review] Reached the " .. boundary .. " file")
    return
  end

  M.close()
  require("gh_review.diff").open(state.get(files[target_index], "path", ""))
end

function M.next_file() move_file(1) end
function M.prev_file() move_file(-1) end

function M.open_current_file()
  if state.get_pr_id() == "" then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  -- Both sides of an existing review diff represent state.get_diff_path(); the
  -- URI-backed base buffer has no useful filesystem path to resolve, and the
  -- checked-out head buffer would resolve to the same path anyway.
  if vim.b[source_bufnr].gh_review_diff and state.get_diff_path() ~= "" then return end

  local buffer_name = vim.api.nvim_buf_get_name(source_bufnr)
  local absolute = buffer_name ~= "" and vim.fs.normalize(buffer_name) or ""
  local root = absolute ~= "" and vim.fs.root(absolute, ".git") or nil
  if not root then
    vim.notify("[gh-review] Current buffer is not a file in a Git repository", vim.log.levels.ERROR)
    return
  end
  root = vim.fs.normalize(root)
  local prefix = root .. "/"
  if absolute:sub(1, #prefix) ~= prefix then
    vim.notify("[gh-review] Could not resolve the current file relative to its repository", vim.log.levels.ERROR)
    return
  end

  local path = absolute:sub(#prefix + 1)
  if path == state.get_diff_path() then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  require("gh_review.diff").open(path, function(_, right_bufnr)
    local winid = right_bufnr and vim.fn.bufwinid(right_bufnr) or -1
    if winid == -1 or not vim.api.nvim_win_is_valid(winid) then return end
    local line_count = vim.api.nvim_buf_line_count(right_bufnr)
    local target_line = math.max(1, math.min(cursor[1], line_count))
    local text = vim.api.nvim_buf_get_lines(right_bufnr, target_line - 1, target_line, false)[1] or ""
    -- Neovim columns are zero-based byte offsets. Clamp when the reviewed head
    -- line is shorter than the working-tree line that supplied the cursor.
    local target_col = math.min(cursor[2], #text)
    vim.fn.win_gotoid(winid)
    vim.api.nvim_win_set_cursor(winid, { target_line, target_col })
  end)
end

return M
