-- Tests for the repository-wide review-thread picker and navigation.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")

h.run_test("Thread selector sorts, labels, navigates, and opens selection", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  local threads = fixtures.mock_thread_nodes()
  -- Pending is a property of any draft comment in the conversation, not of
  -- whichever comment happens to be returned last.
  threads[4].comments.nodes[#threads[4].comments.nodes + 1] = {
    id = "later_comment",
    body = "Later submitted reply",
    author = { login = "bob" },
    pullRequestReview = { id = "submitted_review", state = "COMMENTED" },
  }
  state.set_threads(threads)

  local opened_path
  local opened_thread
  package.loaded["gh_review.diff"] = {
    open = function(path, callback)
      opened_path = path
      local content = {}
      for i = 1, 30 do content[i] = "line " .. i end
      local right = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(right, 0, -1, false, content)
      vim.cmd("buffer " .. right)
      local left = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(left, 0, -1, false, content)
      vim.cmd("aboveleft vnew")
      vim.cmd("buffer " .. left)
      state.set_left_bufnr(left)
      state.set_right_bufnr(right)
      callback(left, right)
    end,
  }
  package.loaded["gh_review.thread"] = {
    open = function(id) opened_thread = id end,
  }
  package.loaded["gh_review.thread_select"] = nil

  require("gh_review.thread_select").open()
  local picker_winid = vim.api.nvim_get_current_win()
  local picker_bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)

  h.assert_equal("gh-review-threads", vim.bo[picker_bufnr].filetype)
  h.assert_match("src/existing.ts:5", lines[1], "file and line sort before new_file threads")
  h.assert_match("%[pending%]", lines[1])
  h.assert_match("Pending note", lines[1])
  h.assert_match("%[active%]", lines[2])
  h.assert_match("%[resolved%]", lines[4])

  vim.fn.maparg("u", "n", false, true).callback()
  lines = vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)
  h.assert_equal(3, #lines, "unresolved filter excludes the resolved thread")
  h.assert_false(table.concat(lines, "\n"):find("%[resolved%]"), "resolved thread is hidden")

  vim.fn.maparg("p", "n", false, true).callback()
  lines = vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)
  h.assert_equal(1, #lines, "pending filter includes only pending threads")
  h.assert_match("%[pending%]", lines[1])

  vim.fn.maparg("a", "n", false, true).callback()
  lines = vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)
  h.assert_equal(4, #lines, "all filter restores every thread")

  vim.fn.maparg("p", "n", false, true).callback()

  vim.api.nvim_win_set_cursor(picker_winid, { 1, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()

  h.assert_equal("src/existing.ts", opened_path)
  h.assert_equal("thread_4", opened_thread)
  local left_winid = vim.fn.bufwinid(state.get_left_bufnr())
  h.assert_equal(5, vim.api.nvim_win_get_cursor(left_winid)[1])
  h.assert_false(vim.api.nvim_win_is_valid(picker_winid), "selection closes the picker")

  vim.cmd("only")
  package.loaded["gh_review.diff"] = nil
  package.loaded["gh_review.thread"] = nil
  package.loaded["gh_review.thread_select"] = nil
end)

h.run_test("Thread selector keeps an empty filter open", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  local threads = fixtures.mock_thread_nodes()
  threads[4].comments.nodes[1].pullRequestReview.state = "COMMENTED"
  state.set_threads(threads)
  package.loaded["gh_review.thread_select"] = nil

  require("gh_review.thread_select").open()
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.fn.maparg("p", "n", false, true).callback()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  h.assert_equal(1, #lines)
  h.assert_equal("No pending threads", lines[1])
  vim.fn.maparg("<CR>", "n", false, true).callback()
  h.assert_true(vim.api.nvim_win_is_valid(winid), "empty filter cannot select a placeholder")

  vim.fn.maparg("q", "n", false, true).callback()
  h.assert_false(vim.api.nvim_win_is_valid(winid), "empty filter can still be closed")
  package.loaded["gh_review.thread_select"] = nil
end)

h.run_test("Thread selector exports the active filter through cfile", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_local_checkout(true)
  package.loaded["gh_review.thread_select"] = nil

  require("gh_review.thread_select").open()
  local picker_winid = vim.api.nvim_get_current_win()
  vim.fn.maparg("p", "n", false, true).callback()
  vim.fn.maparg("c", "n", false, true).callback()

  local items = vim.fn.getqflist()
  h.assert_equal(1, #items, "only the pending-filter row is exported")
  h.assert_equal(5, items[1].lnum)
  h.assert_match("%[pending%]", items[1].text)
  h.assert_match("alice: Pending note", items[1].text)
  h.assert_match("src/existing.ts$", vim.api.nvim_buf_get_name(items[1].bufnr))
  h.assert_false(vim.api.nvim_win_is_valid(picker_winid), "export closes the thread picker")
  h.assert_true(vim.fn.getqflist({ winid = 0 }).winid ~= 0, "quickfix window is opened")

  vim.cmd("cclose")
  package.loaded["gh_review.thread_select"] = nil
end)

h.run_test("GHReviewThreads command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewThreads"))
end)

h.write_results("/tmp/gh_review_test_threads.txt")
