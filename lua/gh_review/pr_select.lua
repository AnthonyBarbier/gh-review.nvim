-- Active pull-request picker for the current repository.

local api_mod = require("gh_review.api")
local graphql = require("gh_review.graphql")
local state = require("gh_review.state")
local config = require("gh_review.config")

local M = {}
local picker_bufnr = -1
local picker_winid = -1

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

local function format_pr(pr)
  local reviewed = pr.reviewed and "[reviewed]" or ""
  local draft = state.get(pr, "isDraft", false) and "[draft]" or ""
  return string.format("#%-6d  %s  %-10s  %-7s  %-16s  %s",
    state.get(pr, "number", 0), state.get(pr, "updatedAt", ""):sub(1, 10),
    reviewed, draft, state.get(state.get(pr, "author", {}), "login", "unknown"),
    state.get(pr, "title", ""))
end

local function sort_prs(prs)
  table.sort(prs, function(left, right)
    if left.reviewed ~= right.reviewed then return left.reviewed end
    local left_updated = state.get(left, "updatedAt", "")
    local right_updated = state.get(right, "updatedAt", "")
    if left_updated ~= right_updated then return left_updated > right_updated end
    return state.get(left, "number", 0) > state.get(right, "number", 0)
  end)
end

local function has_configured_label(pr)
  local wanted = config.options.label
  if wanted == "" then return true end

  -- GitHub label names are case-insensitive. Filter after fetching so the
  -- existing pagination and reviewed-first ordering remain one shared path
  -- for configured and unconfigured selectors.
  wanted = wanted:lower()
  local labels = state.get(state.get(pr, "labels", {}), "nodes", {})
  for _, label in ipairs(labels) do
    if state.get(label, "name", ""):lower() == wanted then return true end
  end
  return false
end

local function open_picker(prs)
  close_picker()
  if #prs == 0 then
    vim.notify("[gh-review] No active pull requests found")
    return
  end

  sort_prs(prs)
  local max_width = vim.fn.strdisplaywidth("Select active PR · reviewed by me · i/l/a")
  for _, pr in ipairs(prs) do
    local line = format_pr(pr)
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  if config.options.label ~= "" then
    max_width = math.max(max_width,
      vim.fn.strdisplaywidth("Select active PR · label: " .. config.options.label .. " · i/l/a"))
  end

  picker_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_bufnr].buftype = "nofile"
  vim.bo[picker_bufnr].bufhidden = "wipe"
  vim.bo[picker_bufnr].swapfile = false
  vim.bo[picker_bufnr].filetype = "gh-review-prs"

  local width = math.min(max_width, math.max(1, vim.o.columns - 4))
  local height = math.min(#prs, math.max(1, vim.o.lines - 4))
  picker_winid = vim.api.nvim_open_win(picker_bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Select active PR · i/l/a ",
    title_pos = "center",
  })
  vim.wo[picker_winid].cursorline = true
  vim.wo[picker_winid].wrap = false

  local displayed_prs = {}

  local function filter_title(filter)
    if filter == "involved" then return "reviewed by me" end
    if filter == "label" then return "label: " .. config.options.label end
    return "all"
  end

  local function set_filter(filter)
    if filter == "label" and config.options.label == "" then
      vim.notify("[gh-review] No label configured; set opts.label to use this filter", vim.log.levels.WARN)
      return
    end

    displayed_prs = {}
    for _, pr in ipairs(prs) do
      if filter == "all"
          or (filter == "involved" and pr.reviewed)
          or (filter == "label" and has_configured_label(pr)) then
        displayed_prs[#displayed_prs + 1] = pr
      end
    end

    -- Keep an empty filter switchable instead of closing the picker: the user
    -- can immediately press another filter key without refetching GitHub data.
    local lines = {}
    for _, pr in ipairs(displayed_prs) do lines[#lines + 1] = format_pr(pr) end
    if #lines == 0 then lines[1] = "No matching pull requests" end
    vim.bo[picker_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, lines)
    vim.bo[picker_bufnr].modifiable = false

    local new_height = math.min(#lines, math.max(1, vim.o.lines - 4))
    vim.api.nvim_win_set_config(picker_winid, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - new_height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = new_height,
      title = " Select active PR · " .. filter_title(filter) .. " · i/l/a ",
      title_pos = "center",
    })
    vim.api.nvim_win_set_cursor(picker_winid, { 1, 0 })
  end

  local function choose_current()
    local pr = displayed_prs[vim.api.nvim_win_get_cursor(picker_winid)[1]]
    if not pr then return end
    close_picker()
    -- Reuse the normal open path so checkout policy, metadata loading, and UI
    -- initialization cannot diverge between :GHReview and :GHReviewSelect.
    require("gh_review").open(tostring(pr.number))
  end
  local map_opts = { buffer = picker_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", choose_current, map_opts)
  vim.keymap.set("n", "q", close_picker, map_opts)
  vim.keymap.set("n", "<Esc>", close_picker, map_opts)
  vim.keymap.set("n", "<C-c>", close_picker, map_opts)
  vim.keymap.set("n", "i", function() set_filter("involved") end, map_opts)
  vim.keymap.set("n", "l", function() set_filter("label") end, map_opts)
  vim.keymap.set("n", "a", function() set_filter("all") end, map_opts)

  -- A configured label used to filter the selector unconditionally. Starting
  -- on that view preserves existing setups while still making all PRs one key
  -- press away; without a label, retain the historical all-PR default.
  set_filter(config.options.label ~= "" and "label" or "all")
end

local function fetch_open_prs(viewer, callback)
  local prs = {}
  local function fetch_page(cursor)
    local vars = {
      owner = state.get_owner(),
      name = state.get_name(),
      viewer = viewer,
    }
    if cursor then vars.cursor = cursor end
    api_mod.graphql(graphql.QUERY_OPEN_PULL_REQUESTS, vars, function(result, err)
      if err then callback(nil) return end
      local data = state.get(result, "data", {})
      local repo = state.get(data, "repository", {})
      local connection = state.get(repo, "pullRequests", {})
      for _, pr in ipairs(state.get(connection, "nodes", {})) do
        local reviews = state.get(pr, "reviews", {})
        pr.reviewed = state.get(reviews, "totalCount", 0) > 0
        prs[#prs + 1] = pr
      end
      local page_info = state.get(connection, "pageInfo", {})
      if state.get(page_info, "hasNextPage", false) then
        local next_cursor = state.get(page_info, "endCursor", nil)
        if not next_cursor then
          vim.notify("[gh-review] GitHub returned an incomplete pull request page", vim.log.levels.ERROR)
          callback(nil)
          return
        end
        fetch_page(next_cursor)
      else
        callback(prs)
      end
    end)
  end
  fetch_page(nil)
end

function M.open()
  api_mod.graphql(graphql.QUERY_VIEWER_LOGIN, {}, function(result, err)
    if err then return end
    local viewer = state.get(state.get(result, "data", {}).viewer, "login", "")
    if viewer == "" then
      vim.notify("[gh-review] Could not determine the current GitHub user", vim.log.levels.ERROR)
      return
    end
    fetch_open_prs(viewer, function(prs)
      if prs then open_picker(prs) end
    end)
  end)
end

return M
