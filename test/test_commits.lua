-- Tests for selecting a commit-to-head review range.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")

local function setup_state()
  state.reset()
  state.set_repo_info("testowner", "testrepo")
  state.set_pr(fixtures.mock_pr_data())
  state.set_merge_base_oid("merge000")
  state.set_diff_base_oid("merge000")
end

local function commit(oid, headline, date, login)
  return {
    oid = oid,
    messageHeadline = headline,
    committedDate = date,
    author = { name = login, user = { login = login } },
  }
end

local function load_with_mocks(select_index)
  local graphql_calls = {}
  local review_graphql_calls = {}
  local compare_endpoint
  local close_count = 0
  local rerender_count = 0

  package.loaded["gh_review.api"] = {
    graphql = function(query, vars, callback)
      if query == require("gh_review.graphql").QUERY_PR_COMMITS then
        graphql_calls[#graphql_calls + 1] = vars
      elseif query == require("gh_review.graphql").QUERY_MY_LAST_REVIEW then
        review_graphql_calls[#review_graphql_calls + 1] = vars
        if #review_graphql_calls == 1 then
          callback({ data = {
            viewer = { login = "alice" },
            repository = { pullRequest = { reviews = {
              nodes = {
                { author = { login = "bob" }, submittedAt = "2026-01-03T10:00:00Z", commit = { oid = "22222222bbbb" } },
              },
              pageInfo = { hasPreviousPage = true, startCursor = "reviews-page-2" },
            } } },
          } })
        else
          callback({ data = {
            viewer = { login = "alice" },
            repository = { pullRequest = { reviews = {
              nodes = {
                { author = { login = "alice" }, submittedAt = "2026-01-01T12:00:00Z", commit = { oid = "11111111aaaa" } },
              },
              pageInfo = { hasPreviousPage = false, startCursor = vim.NIL },
            } } },
          } })
        end
        return
      else
        error("unexpected GraphQL query")
      end

      if #graphql_calls == 1 then
        callback({ data = { repository = { pullRequest = { commits = {
          nodes = { { commit = commit("11111111aaaa", "First", "2026-01-01T10:00:00Z", "alice") } },
          pageInfo = { hasNextPage = true, endCursor = "page-2" },
        } } } } })
      else
        callback({ data = { repository = { pullRequest = { commits = {
          nodes = { { commit = commit("22222222bbbb", "Second", "2026-01-02T10:00:00Z", "bob") } },
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
        } } } } })
      end
    end,
    run_async = function(args, callback)
      compare_endpoint = args[2]
      callback(vim.json.encode({ files = {
        { filename = "src/later.lua", status = "added", additions = 7, deletions = 0 },
        { filename = "src/removed.lua", status = "removed", additions = 0, deletions = 3 },
        { filename = "src/new-name.lua", previous_filename = "src/old-name.lua", status = "renamed", additions = 1, deletions = 1 },
      } }), "")
    end,
  }
  package.loaded["gh_review.diff"] = {
    close_diff = function() close_count = close_count + 1 end,
  }
  package.loaded["gh_review.files"] = {
    rerender = function() rerender_count = rerender_count + 1 end,
  }
  package.loaded["gh_review.commits"] = nil

  require("gh_review.commits").choose()

  local picker_winid = vim.api.nvim_get_current_win()
  local picker_bufnr = vim.api.nvim_get_current_buf()
  local picker_lines = vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)
  local picker_extmarks = vim.api.nvim_buf_get_extmarks(picker_bufnr, -1, 0, -1, { details = true })
  -- The reset row stays first, commits are newest-first, and only the viewer's
  -- last reviewed commit carries the annotation highlight.
  h.assert_equal("Full PR (merge base .. head)", picker_lines[1])
  h.assert_match("22222222", picker_lines[2])
  h.assert_false(picker_lines[2]:find("last reviewed", 1, true) ~= nil)
  h.assert_match("last reviewed", picker_lines[3])
  h.assert_equal("gh-review-commits", vim.bo[picker_bufnr].filetype)
  h.assert_true(vim.wo[picker_winid].cursorline)

  vim.api.nvim_win_set_cursor(picker_winid, { select_index, 0 })
  local enter_map = vim.fn.maparg("<CR>", "n", false, true)
  h.assert_equal("function", type(enter_map.callback))
  enter_map.callback()

  return {
    graphql_calls = graphql_calls,
    review_graphql_calls = review_graphql_calls,
    compare_endpoint = compare_endpoint,
    close_count = close_count,
    rerender_count = rerender_count,
    picker_lines = picker_lines,
    picker_extmarks = picker_extmarks,
    picker_closed = not vim.api.nvim_win_is_valid(picker_winid),
  }
end

h.run_test("Commit picker paginates and applies the selected commit-to-head range", function()
  setup_state()
  local result = load_with_mocks(2)

  h.assert_equal(2, #result.graphql_calls)
  h.assert_equal(nil, result.graphql_calls[1].cursor)
  h.assert_equal("page-2", result.graphql_calls[2].cursor)
  h.assert_equal(2, #result.review_graphql_calls)
  h.assert_equal(nil, result.review_graphql_calls[1].cursor)
  h.assert_equal("reviews-page-2", result.review_graphql_calls[2].cursor)
  h.assert_equal("22222222bbbb", state.get_diff_base_oid())
  h.assert_match("compare/22222222bbbb%.%.%.bbb222", result.compare_endpoint)
  h.assert_equal(3, #state.get_changed_files())
  h.assert_equal("ADDED", state.get_changed_files()[1].changeType)
  h.assert_equal("DELETED", state.get_changed_files()[2].changeType)
  h.assert_equal("src/old-name.lua", state.get_changed_files()[3].previousPath)
  h.assert_equal(1, result.close_count)
  h.assert_equal(1, result.rerender_count)
  h.assert_true(result.picker_closed)
  h.assert_equal(1, #result.picker_extmarks)
  h.assert_equal(2, result.picker_extmarks[1][2])
  local highlight = result.picker_extmarks[1][4].hl_group
  h.assert_equal("GHReviewLastReviewed", highlight)
  local annotation_hl = vim.api.nvim_get_hl(0, { name = highlight, link = false })
  local theme_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  h.assert_true(annotation_hl.bold, "last-reviewed annotation is bold")
  h.assert_equal(theme_hl.fg, annotation_hl.fg, "annotation inherits theme color")
end)

h.run_test("Commit picker full-PR row restores merge base and original files", function()
  setup_state()
  state.set_diff_base_oid("later111")
  state.set_changed_files({ { path = "src/later.lua", changeType = "ADDED" } })
  local result = load_with_mocks(1)

  h.assert_equal("merge000", state.get_diff_base_oid())
  h.assert_equal(3, #state.get_changed_files())
  h.assert_equal(nil, result.compare_endpoint)
  h.assert_equal(1, result.close_count)
  h.assert_equal(1, result.rerender_count)
end)

h.run_test("GHReviewCommits command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewCommits"))
end)

h.write_results("/tmp/gh_review_test_commits.txt")
