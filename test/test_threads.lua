-- Tests for the repository-wide review-thread picker and navigation.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")

h.run_test("Thread selector sorts, labels, navigates, and opens selection", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())

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

h.run_test("GHReviewThreads command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewThreads"))
end)

h.write_results("/tmp/gh_review_test_threads.txt")
