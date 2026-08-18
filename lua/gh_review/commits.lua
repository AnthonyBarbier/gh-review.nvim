-- PR commit picker and diff-range selection.

local api_mod = require("gh_review.api")
local graphql = require("gh_review.graphql")
local state = require("gh_review.state")

local M = {}
local picker_ns = vim.api.nvim_create_namespace("gh_review_commits")
local picker_bufnr = -1
local picker_winid = -1

-- GitHub's compare response uses REST status names, while the rest of the
-- plugin consumes GraphQL-style changeType values.  Diff rendering only needs
-- to distinguish additions and deletions from files present on both sides, so
-- renamed/copied/changed files deliberately use the modified path.
local function compare_files(files)
  local result = {}
  for _, file in ipairs(files or {}) do
    local change_type = "MODIFIED"
    if file.status == "added" then
      change_type = "ADDED"
    elseif file.status == "removed" then
      change_type = "DELETED"
    end
    result[#result + 1] = {
      path = file.filename,
      -- The files list and head buffer use the new name, while the base blob
      -- must be fetched under the old name for a rename in the chosen range.
      previousPath = file.previous_filename,
      additions = file.additions or 0,
      deletions = file.deletions or 0,
      changeType = change_type,
    }
  end
  return result
end

local function fetch_commits(callback)
  local commits = {}

  local function fetch_page(cursor)
    local vars = {
      owner = state.get_owner(),
      name = state.get_name(),
      number = state.get_pr_number(),
    }
    -- Omitting a nullable cursor represents the first page.  Passing vim.NIL
    -- through the gh CLI would stringify it instead of sending GraphQL null.
    if cursor then vars.cursor = cursor end

    api_mod.graphql(graphql.QUERY_PR_COMMITS, vars, function(result, err)
      if err then
        callback(nil)
        return
      end
      local data = state.get(result, "data", {})
      local repo = state.get(data, "repository", {})
      local pr = state.get(repo, "pullRequest", {})
      local connection = state.get(pr, "commits", {})
      for _, node in ipairs(state.get(connection, "nodes", {})) do
        local commit = state.get(node, "commit", nil)
        if commit then commits[#commits + 1] = commit end
      end

      local page_info = state.get(connection, "pageInfo", {})
      if state.get(page_info, "hasNextPage", false) then
        local next_cursor = state.get(page_info, "endCursor", nil)
        if not next_cursor then
          vim.notify("[gh-review] GitHub returned an incomplete commits page", vim.log.levels.ERROR)
          callback(nil)
          return
        end
        fetch_page(next_cursor)
      else
        callback(commits)
      end
    end)
  end

  fetch_page(nil)
end

local function fetch_last_reviewed_oid(callback)
  local function fetch_page(cursor)
    local vars = {
      owner = state.get_owner(),
      name = state.get_name(),
      number = state.get_pr_number(),
    }
    if cursor then vars.cursor = cursor end

    api_mod.graphql(graphql.QUERY_MY_LAST_REVIEW, vars, function(result, err)
      -- The annotation is helpful context, but failure to load it should not
      -- prevent the user from selecting a range from the commits we did load.
      if err then
        callback(nil)
        return
      end
      local data = state.get(result, "data", {})
      local viewer = state.get(state.get(data, "viewer", {}), "login", "")
      local repo = state.get(data, "repository", {})
      local pr = state.get(repo, "pullRequest", {})
      local connection = state.get(pr, "reviews", {})
      local nodes = state.get(connection, "nodes", {})

      -- A `last` page is chronological, so scan it backwards to find the
      -- viewer's newest submitted review. Pending reviews have no submittedAt.
      for i = #nodes, 1, -1 do
        local review = nodes[i]
        local author = state.get(state.get(review, "author", {}), "login", "")
        local commit = state.get(review, "commit", {})
        if viewer ~= "" and author == viewer and state.get(review, "submittedAt", "") ~= "" then
          callback(state.get(commit, "oid", nil))
          return
        end
      end

      local page_info = state.get(connection, "pageInfo", {})
      if state.get(page_info, "hasPreviousPage", false) then
        local previous_cursor = state.get(page_info, "startCursor", nil)
        if previous_cursor then
          fetch_page(previous_cursor)
          return
        end
      end
      callback(nil)
    end)
  end

  fetch_page(nil)
end

local function author_name(commit)
  local author = state.get(commit, "author", {})
  local user = state.get(author, "user", {})
  return state.get(user, "login", state.get(author, "name", "unknown"))
end

local function format_commit(item)
  if item.full_pr then return "Full PR (merge base .. head)" end
  local commit = item.commit
  local date = state.get(commit, "committedDate", ""):sub(1, 10)
  local annotation = item.last_reviewed and "[last reviewed]" or ""
  -- Keep the marker beside the OID so it remains visible when a long subject
  -- extends past the floating window's available width.
  return string.format("%s  %-15s  %s  %-16s  %s",
    state.get(commit, "oid", ""):sub(1, 8), annotation, date,
    author_name(commit), state.get(commit, "messageHeadline", ""))
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

local function open_picker(items, callback)
  close_picker()

  -- Resolve the semantic color on every open so changing colorschemes between
  -- invocations is reflected without a plugin-specific palette or autocmd.
  local last_reviewed_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  last_reviewed_hl.bold = true
  vim.api.nvim_set_hl(0, "GHReviewLastReviewed", last_reviewed_hl)

  local lines = {}
  local max_width = vim.fn.strdisplaywidth("Diff changes after commit:")
  for _, item in ipairs(items) do
    local line = format_commit(item)
    lines[#lines + 1] = line
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  picker_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_bufnr].buftype = "nofile"
  vim.bo[picker_bufnr].bufhidden = "wipe"
  vim.bo[picker_bufnr].swapfile = false
  vim.bo[picker_bufnr].filetype = "gh-review-commits"
  vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, lines)

  for line_idx, item in ipairs(items) do
    if item.last_reviewed then
      local start_col = lines[line_idx]:find("[last reviewed]", 1, true)
      if start_col then
        -- GHReviewLastReviewed copies the active theme's DiagnosticInfo
        -- attributes and adds bold emphasis without hard-coding a color.
        vim.api.nvim_buf_set_extmark(picker_bufnr, picker_ns, line_idx - 1, start_col - 1, {
          end_col = start_col - 1 + #"[last reviewed]",
          hl_group = "GHReviewLastReviewed",
          priority = 200,
        })
      end
    end
  end
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
    title = " Diff changes after commit ",
    title_pos = "center",
  })
  vim.wo[picker_winid].cursorline = true
  vim.wo[picker_winid].wrap = false

  local function choose_current()
    local choice = items[vim.api.nvim_win_get_cursor(picker_winid)[1]]
    close_picker()
    callback(choice)
  end
  local function cancel()
    close_picker()
  end
  local map_opts = { buffer = picker_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", choose_current, map_opts)
  vim.keymap.set("n", "q", cancel, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)
  vim.keymap.set("n", "<C-c>", cancel, map_opts)
end

local function apply_range(base_oid, changed_files, full_pr)
  -- Close first so no buffers remain labelled with the previous range.  The
  -- files window survives close_diff() and is rerendered in place below.
  require("gh_review.diff").close_diff()
  state.set_diff_base_oid(base_oid)
  if full_pr then
    state.restore_full_pr_files()
  else
    state.set_changed_files(changed_files)
  end
  require("gh_review.files").rerender()
end

local function select_commit(commits, last_reviewed_oid)
  local items = { { full_pr = true } }
  -- GitHub returns oldest first.  Recent commits are more likely to represent
  -- the last reviewed point, so present them newest first after the reset row.
  for i = #commits, 1, -1 do
    items[#items + 1] = {
      commit = commits[i],
      last_reviewed = state.get(commits[i], "oid", "") == last_reviewed_oid,
    }
  end

  open_picker(items, function(choice)
    if not choice then return end
    if choice.full_pr then
      apply_range(state.get_merge_base_oid(), nil, true)
      vim.notify("[gh-review] Diff range reset to the full PR")
      return
    end

    local base_oid = state.get(choice.commit, "oid", "")
    local endpoint = string.format("/repos/%s/%s/compare/%s...%s",
      state.get_owner(), state.get_name(), base_oid, state.get_head_oid())
    api_mod.run_async({ "api", endpoint }, function(stdout, stderr)
      if stderr and stderr ~= "" then
        vim.notify("[gh-review] Could not load selected diff range: " .. vim.trim(stderr), vim.log.levels.ERROR)
        return
      end
      local ok, response = pcall(vim.json.decode, stdout)
      if not ok or type(response) ~= "table" or type(response.files) ~= "table" then
        vim.notify("[gh-review] GitHub returned an invalid compare response", vim.log.levels.ERROR)
        return
      end
      apply_range(base_oid, compare_files(response.files), false)
      vim.notify(string.format("[gh-review] Diff now starts after %s", base_oid:sub(1, 8)))
    end)
  end)
end

function M.choose()
  if state.get_pr_number() == 0 then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end
  local commits
  local last_reviewed_oid
  local fetches_done = 0
  local function handle_done()
    fetches_done = fetches_done + 1
    if fetches_done == 2 and commits then
      select_commit(commits, last_reviewed_oid)
    end
  end
  -- These queries are independent and normally complete in parallel.  The
  -- picker opens only after both return so its annotation does not move later.
  fetch_commits(function(result)
    commits = result
    handle_done()
  end)
  fetch_last_reviewed_oid(function(result)
    last_reviewed_oid = result
    handle_done()
  end)
end

return M
