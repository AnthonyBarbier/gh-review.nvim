-- Tests for the native GHReview command menu.

local h = require("test.helpers")

h.run_test("GHReview menu renders actions and runs letter shortcuts", function()
  local review = require("gh_review")
  local methods = {
    r = { method = "open", expected = "" },
    p = { method = "select_pr" },
    c = { method = "choose_commit" },
    s = { method = "submit_review" },
    f = { method = "toggle_files" },
    t = { method = "choose_thread" },
  }

  for key, expectation in pairs(methods) do
    local original = review[expectation.method]
    local called = false
    review[expectation.method] = function(argument)
      called = true
      h.assert_equal(expectation.expected, argument)
    end

    require("gh_review.menu").open()
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    h.assert_equal(6, #lines)
    h.assert_equal("gh-review-menu", vim.bo[bufnr].filetype)
    h.assert_true(vim.wo[winid].cursorline)
    vim.fn.maparg(key, "n", false, true).callback()

    review[expectation.method] = original
    h.assert_true(called, key .. " invokes " .. expectation.method)
    h.assert_false(vim.api.nvim_win_is_valid(winid), "action closes the menu")
  end
end)

h.run_test("GHReview menu opens the highlighted action with Enter", function()
  local review = require("gh_review")
  local original = review.submit_review
  local called = false
  review.submit_review = function() called = true end

  require("gh_review.menu").open()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(winid, { 4, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  review.submit_review = original

  h.assert_true(called)
  h.assert_false(vim.api.nvim_win_is_valid(winid))
end)

h.run_test("GHReviewMenu command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewMenu"))
end)

h.write_results("/tmp/gh_review_test_menu.txt")
