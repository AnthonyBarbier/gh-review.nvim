-- Tests for selecting an active pull request from the current repository.

local h = require("test.helpers")
local state = require("gh_review.state")
local graphql = require("gh_review.graphql")

local function pr(number, title, updated_at, reviewed)
  return {
    number = number,
    title = title,
    updatedAt = updated_at,
    isDraft = false,
    author = { login = "author" .. number },
    reviews = { totalCount = reviewed and 1 or 0 },
  }
end

h.run_test("PR selector paginates, groups reviewed PRs first, and opens selection", function()
  state.reset()
  state.set_repo_info("testowner", "testrepo")
  local page_calls = {}
  package.loaded["gh_review.api"] = {
    graphql = function(query, vars, callback)
      if query == graphql.QUERY_VIEWER_LOGIN then
        callback({ data = { viewer = { login = "alice" } } })
        return
      end
      h.assert_equal(graphql.QUERY_OPEN_PULL_REQUESTS, query)
      page_calls[#page_calls + 1] = vars
      if #page_calls == 1 then
        callback({ data = { repository = { pullRequests = {
          nodes = {
            pr(10, "Newest other", "2026-08-05T12:00:00Z", false),
            pr(20, "Newest reviewed", "2026-08-04T12:00:00Z", true),
          },
          pageInfo = { hasNextPage = true, endCursor = "page-2" },
        } } } })
      else
        callback({ data = { repository = { pullRequests = {
          nodes = {
            pr(30, "Older reviewed", "2026-08-03T12:00:00Z", true),
            pr(40, "Older other", "2026-08-02T12:00:00Z", false),
          },
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
        } } } })
      end
    end,
  }
  package.loaded["gh_review.pr_select"] = nil

  local init = require("gh_review")
  local original_open = init.open
  local opened_number
  init.open = function(number) opened_number = number end
  require("gh_review.pr_select").open()

  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  h.assert_match("#20", lines[1], "most recently updated reviewed PR comes first")
  h.assert_match("%[reviewed%]", lines[1])
  h.assert_match("#30", lines[2], "older reviewed PR stays ahead of other PRs")
  h.assert_match("#10", lines[3], "other group is independently update-sorted")
  h.assert_match("#40", lines[4])
  h.assert_equal("gh-review-prs", vim.bo[bufnr].filetype)
  h.assert_true(vim.wo[winid].cursorline)

  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  init.open = original_open

  h.assert_equal("20", opened_number)
  h.assert_equal(2, #page_calls)
  h.assert_equal("alice", page_calls[1].viewer)
  h.assert_equal(nil, page_calls[1].cursor)
  h.assert_equal("page-2", page_calls[2].cursor)
  h.assert_false(vim.api.nvim_win_is_valid(winid), "selection closes the picker")
end)

h.run_test("GHReviewSelect command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewSelect"))
end)

h.write_results("/tmp/gh_review_test_select.txt")
