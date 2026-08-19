-- Tests for thread buffer: content rendering, metadata, buffer options,
-- code context, and close behaviour.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local thread = require("gh_review.thread")

local function setup_diff_buffers(path, num_lines)
  local left_name = "gh-review://LEFT/" .. path
  local right_name = "gh-review://RIGHT/" .. path

  local lines = {}
  for i = 1, num_lines do
    lines[i] = "line " .. i
  end

  vim.cmd("enew")
  local left = vim.fn.bufnr(left_name, true)
  vim.cmd("buffer " .. left)
  vim.bo[left].buftype = "nofile"
  vim.bo[left].swapfile = false
  vim.bo[left].bufhidden = "hide"
  vim.bo[left].modifiable = true
  vim.api.nvim_buf_set_lines(left, 0, -1, false, lines)
  vim.bo[left].modifiable = false
  state.set_left_bufnr(left)

  vim.cmd("enew")
  local right = vim.fn.bufnr(right_name, true)
  vim.cmd("buffer " .. right)
  vim.bo[right].buftype = "nofile"
  vim.bo[right].swapfile = false
  vim.bo[right].bufhidden = "hide"
  vim.bo[right].modifiable = true
  vim.api.nvim_buf_set_lines(right, 0, -1, false, lines)
  vim.bo[right].modifiable = false
  state.set_right_bufnr(right)
end

local function cleanup_diff_buffers()
  local left = state.get_left_bufnr()
  local right = state.get_right_bufnr()
  if left ~= -1 and vim.fn.bufexists(left) == 1 then
    vim.cmd("bwipeout! " .. left)
  end
  if right ~= -1 and vim.fn.bufexists(right) == 1 then
    vim.cmd("bwipeout! " .. right)
  end
  state.set_left_bufnr(-1)
  state.set_right_bufnr(-1)
end

h.run_test("Thread buffer: existing thread renders header and comments", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")

  local bufnr = state.get_thread_bufnr()
  h.assert_true(bufnr ~= -1, "thread bufnr should be set")
  h.assert_true(vim.fn.bufexists(bufnr) == 1, "thread buffer should exist")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("Thread on", lines[1])
  h.assert_match("src/new_file.ts", lines[1])
  h.assert_match(":10", lines[1])
  h.assert_match("%[Active%]", lines[1])

  h.assert_match("alice", all_text)
  h.assert_match("2025%-01%-15", all_text)
  h.assert_match("Looks good", all_text)

  h.assert_match("Reply below", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: resolved thread shows Resolved status", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_2")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("%[Resolved%]", lines[1])

  h.assert_match("bob", all_text)
  h.assert_match("Fix this", all_text)
  h.assert_match("alice", all_text)
  h.assert_match("Done", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: new comment renders New header", function()
  state.reset()
  setup_diff_buffers("src/test.ts", 20)
  state.set_diff_path("src/test.ts")

  thread.open_new("src/test.ts", 5, 5, "RIGHT", "placeholder")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  h.assert_match("New comment on", lines[1])
  h.assert_match("src/test.ts", lines[1])
  h.assert_match(":5", lines[1])
  h.assert_match("%[New%]", lines[1])

  h.assert_true(vim.b[bufnr].gh_review_is_new)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: metadata variables set correctly", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()

  h.assert_equal("thread_1", vim.b[bufnr].gh_review_thread_id)
  h.assert_equal("src/new_file.ts", vim.b[bufnr].gh_review_path)
  h.assert_equal(10, vim.b[bufnr].gh_review_line)
  h.assert_equal("RIGHT", vim.b[bufnr].gh_review_side)
  h.assert_false(vim.b[bufnr].gh_review_is_new)
  h.assert_false(vim.b[bufnr].gh_review_is_resolved)
  h.assert_equal("comment_1", vim.b[bufnr].gh_review_first_comment_id)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: resolved thread metadata", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_2")
  local bufnr = state.get_thread_bufnr()

  h.assert_true(vim.b[bufnr].gh_review_is_resolved)
  h.assert_equal("comment_2", vim.b[bufnr].gh_review_first_comment_id)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: outdated thread falls back to originalLine", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/existing.ts", 30)
  state.set_diff_path("src/existing.ts")

  thread.open("thread_3")
  local bufnr = state.get_thread_bufnr()

  h.assert_equal(8, vim.b[bufnr].gh_review_line)
  local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  h.assert_match(":8", first_line)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: buffer options are correct", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()

  h.assert_equal("acwrite", vim.bo[bufnr].buftype)
  h.assert_equal("wipe", vim.bo[bufnr].bufhidden)
  h.assert_false(vim.bo[bufnr].swapfile)
  h.assert_equal("gh-review-thread", vim.bo[bufnr].filetype)
  local winid = vim.fn.bufwinid(bufnr)
  h.assert_true(vim.wo[winid].wrap)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: close cleans up state", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  h.assert_true(state.get_thread_bufnr() ~= -1, "thread bufnr should be set before close")

  thread.close_thread_buffer()

  h.assert_equal(-1, state.get_thread_bufnr(), "thread bufnr should be -1 after close")
  h.assert_equal(-1, state.get_thread_winid(), "thread winid should be -1 after close")

  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: initial body (suggestion) rendered", function()
  state.reset()
  setup_diff_buffers("src/test.ts", 20)
  state.set_diff_path("src/test.ts")

  local suggestion = "```suggestion\nsome code\n```"
  thread.open_new("src/test.ts", 5, 5, "RIGHT", suggestion)

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("suggestion", all_text)
  h.assert_match("some code", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: code context from right buffer uses + prefix", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("10 %+", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: multi-line thread shows range context", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_2")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("20 %+", all_text)
  h.assert_match("25 %+", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: LEFT side uses - prefix in context", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/existing.ts", 30)
  state.set_diff_path("src/existing.ts")

  thread.open("thread_4")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("5 %-", all_text)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: date formatting strips time portion", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")

  local bufnr = state.get_thread_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_text = table.concat(lines, "\n")

  h.assert_match("2025%-01%-15", all_text)
  h.assert_false(all_text:find("T10:30"), "should not contain time portion")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: opening new thread closes previous one", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local first_bufnr = state.get_thread_bufnr()
  h.assert_true(first_bufnr ~= -1)

  thread.open("thread_2")
  local second_bufnr = state.get_thread_bufnr()
  h.assert_true(second_bufnr ~= -1)
  h.assert_false(vim.fn.bufexists(first_bufnr) == 1, "first thread buffer should be wiped")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: close expands diff windows into freed space", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_diff_path("src/new_file.ts")

  local lines = {}
  for i = 1, 30 do
    lines[i] = "line " .. i
  end

  vim.cmd("enew")
  local right_bufnr = vim.fn.bufnr("gh-review://RIGHT/src/new_file.ts", true)
  vim.cmd("buffer " .. right_bufnr)
  vim.bo[right_bufnr].buftype = "nofile"
  vim.bo[right_bufnr].swapfile = false
  vim.bo[right_bufnr].bufhidden = "hide"
  vim.bo[right_bufnr].modifiable = true
  vim.wo.scrollbind = true
  vim.api.nvim_buf_set_lines(right_bufnr, 0, -1, false, lines)
  vim.bo[right_bufnr].modifiable = false
  state.set_right_bufnr(right_bufnr)

  vim.cmd("aboveleft vnew")
  local left_bufnr = vim.fn.bufnr("gh-review://LEFT/src/new_file.ts", true)
  vim.cmd("buffer " .. left_bufnr)
  vim.bo[left_bufnr].buftype = "nofile"
  vim.bo[left_bufnr].swapfile = false
  vim.bo[left_bufnr].bufhidden = "hide"
  vim.bo[left_bufnr].modifiable = true
  vim.wo.scrollbind = true
  vim.api.nvim_buf_set_lines(left_bufnr, 0, -1, false, lines)
  vim.bo[left_bufnr].modifiable = false
  state.set_left_bufnr(left_bufnr)

  thread.open("thread_1")

  local left_height_before = vim.fn.winheight(vim.fn.bufwinid(left_bufnr))
  local right_height_before = vim.fn.winheight(vim.fn.bufwinid(right_bufnr))

  thread.close_thread_buffer()

  local left_height_after = vim.fn.winheight(vim.fn.bufwinid(left_bufnr))
  local right_height_after = vim.fn.winheight(vim.fn.bufwinid(right_bufnr))
  h.assert_true(left_height_after > left_height_before, "left diff should be taller after thread close")
  h.assert_true(right_height_after > right_height_before, "right diff should be taller after thread close")

  vim.cmd("bwipeout! " .. left_bufnr)
  vim.cmd("bwipeout! " .. right_bufnr)
end)

h.run_test("Thread buffer: reply_start points to line after separator", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start

  h.assert_true(reply_start > 0, "reply_start should be positive")

  local sep_line = vim.api.nvim_buf_get_lines(bufnr, reply_start - 2, reply_start - 1, false)[1]
  h.assert_match("Reply below", sep_line, "line before reply_start should be the separator")

  local reply_line = vim.api.nvim_buf_get_lines(bufnr, reply_start - 1, reply_start, false)[1]
  h.assert_equal("", reply_line, "reply_start line should be blank")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: reply area is editable", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start

  local winid = vim.fn.bufwinid(bufnr)
  vim.fn.win_gotoid(winid)
  vim.api.nvim_win_set_cursor(winid, { reply_start, 0 })
  vim.cmd("doautocmd CursorMoved")
  h.assert_true(vim.bo[bufnr].modifiable, "reply area should be modifiable")

  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, reply_start, false, { "Test reply text" })
  local written = vim.api.nvim_buf_get_lines(bufnr, reply_start - 1, reply_start, false)[1]
  h.assert_equal("Test reply text", written, "should be able to write in reply area")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread buffer: header area is read-only", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()

  local winid = vim.fn.bufwinid(bufnr)
  vim.fn.win_gotoid(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  vim.cmd("doautocmd CursorMoved")
  h.assert_false(vim.bo[bufnr].modifiable, "header area should not be modifiable")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread omnifunc: findstart locates @ symbol", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start

  local winid = vim.fn.bufwinid(bufnr)
  vim.fn.win_gotoid(winid)
  vim.api.nvim_win_set_cursor(winid, { reply_start, 0 })
  vim.cmd("doautocmd CursorMoved")

  -- Type "@al" at the reply line
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, reply_start, false, { "@al" })
  vim.fn.cursor(reply_start, 4) -- position cursor after "@al"

  local col = thread.omnifunc(1, "")
  h.assert_equal(1, col, "findstart should return col of @")

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread omnifunc: base filtering returns matching participants", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())

  local matches = thread.omnifunc(0, "al")
  h.assert_equal(1, #matches, "should match alice")
  h.assert_equal("alice", matches[1])

  local all = thread.omnifunc(0, "")
  h.assert_equal(2, #all, "empty base should return all participants")
end)

h.run_test("Thread buffer: omnifunc is set", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/new_file.ts", 30)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")
  local bufnr = state.get_thread_bufnr()
  h.assert_match("omnifunc", vim.bo[bufnr].omnifunc)

  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread: pending comment is loaded and edited instead of replied to", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  setup_diff_buffers("src/existing.ts", 30)

  thread.open("thread_4")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start
  h.assert_equal("comment_5", vim.b[bufnr].gh_review_edit_comment_id)
  local reply = table.concat(vim.api.nvim_buf_get_lines(bufnr, reply_start - 1, -1, false), "\n")
  h.assert_match("Pending note", reply)
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { "Updated pending note" })

  local api = require("gh_review.api")
  local original_graphql = api.graphql
  local captured = {}
  api.graphql = function(mutation, vars, callback)
    captured.mutation = mutation
    captured.vars = vars
    callback({ data = { updatePullRequestReviewComment = { pullRequestReviewComment = {
      id = "comment_5", body = vars.body,
    } } } })
  end
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  api.graphql = original_graphql

  h.assert_equal(require("gh_review.graphql").MUTATION_UPDATE_REVIEW_COMMENT, captured.mutation)
  h.assert_equal("comment_5", captured.vars.commentId)
  h.assert_equal("Updated pending note", captured.vars.body)
  h.assert_equal("Updated pending note", state.get_thread("thread_4").comments.nodes[1].body)
  h.assert_equal(-1, state.get_thread_bufnr(), "successful update closes the editor")
  cleanup_diff_buffers()
end)

h.run_test("Thread: unchanged pending comment does not call GitHub", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  thread.open("thread_4")

  local api = require("gh_review.api")
  local original_graphql = api.graphql
  local calls = 0
  api.graphql = function() calls = calls + 1 end
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  api.graphql = original_graphql

  h.assert_equal(0, calls)
  h.assert_true(state.get_thread_bufnr() ~= -1, "unchanged editor remains open")
  thread.close_thread_buffer()
end)

h.run_test("Thread: first inline comment records implicitly created pending review", function()
  state.reset()
  local pr_data = fixtures.mock_pr_data()
  pr_data.data.repository.pullRequest.reviews.nodes = {}
  state.set_pr(pr_data)
  setup_diff_buffers("src/new_file.ts", 30)

  thread.open_new("src/new_file.ts", 10, 10, "RIGHT", "")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { "New pending note" })

  local api = require("gh_review.api")
  local original_graphql = api.graphql
  api.graphql = function(_, vars, callback)
    callback({ data = { addPullRequestReviewThread = { thread = {
      id = "new_thread",
      comments = { nodes = { {
        id = "new_comment",
        body = vars.body,
        pullRequestReview = { id = "implicit_pending_review", state = "PENDING" },
      } } },
    } } } })
  end
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  api.graphql = original_graphql

  h.assert_equal("implicit_pending_review", state.get_pending_review_id())
  h.assert_true(state.is_review_active(), "implicit review should become the active review")
  h.assert_equal(-1, state.get_thread_bufnr(), "successful comment closes the editor")
  cleanup_diff_buffers()
end)

h.run_test("Thread: null thread reports a line outside the diff", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  setup_diff_buffers("src/new_file.ts", 30)

  thread.open_new("src/new_file.ts", 10, 10, "RIGHT", "")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { "Comment outside the diff" })

  local api = require("gh_review.api")
  local original_graphql = api.graphql
  local original_notify = vim.notify
  local notification = ""
  api.graphql = function(_, _, callback)
    -- GitHub represents an invalid inline-comment location as a successful
    -- mutation payload whose nullable thread field is JSON null/vim.NIL.
    callback({ data = { addPullRequestReviewThread = { thread = vim.NIL } } })
  end
  vim.notify = function(message) notification = message end
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  vim.notify = original_notify
  api.graphql = original_graphql

  h.assert_match("line is not part of the diff", notification)
  h.assert_true(state.get_thread_bufnr() ~= -1, "failed comment remains open for recovery")
  thread.close_thread_buffer()
  cleanup_diff_buffers()
end)

h.run_test("Thread: multiple pending comments use a picker", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  local nodes = fixtures.mock_thread_nodes()
  nodes[4].comments.nodes[#nodes[4].comments.nodes + 1] = {
    id = "comment_6",
    body = "Second pending note",
    author = { login = "alice" },
    createdAt = "2025-01-16T10:00:00Z",
    pullRequestReview = { id = "pending_rev_1", state = "PENDING" },
  }
  state.set_threads(nodes)

  local original_select = vim.ui.select
  local option_count = 0
  vim.ui.select = function(items, opts, callback)
    option_count = #items
    h.assert_equal("Edit pending comment:", opts.prompt)
    h.assert_match("Second pending note", opts.format_item(items[2]))
    callback(items[2])
  end
  thread.open("thread_4")
  vim.ui.select = original_select

  h.assert_equal(2, option_count)
  local bufnr = state.get_thread_bufnr()
  h.assert_equal("comment_6", vim.b[bufnr].gh_review_edit_comment_id)
  local reply_start = vim.b[bufnr].gh_review_reply_start
  local reply = table.concat(vim.api.nvim_buf_get_lines(bufnr, reply_start - 1, -1, false), "\n")
  h.assert_match("Second pending note", reply)
  thread.close_thread_buffer()
end)

h.run_test("Thread: Ctrl-D confirms and deletes the selected pending comment", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  thread.open("thread_4")

  local original_select = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    h.assert_equal("Delete pending comment?", opts.prompt)
    callback(items[1])
  end
  local api = require("gh_review.api")
  local original_graphql = api.graphql
  local captured = {}
  api.graphql = function(mutation, vars, callback)
    captured.mutation = mutation
    captured.vars = vars
    callback({ data = { deletePullRequestReviewComment = {
      pullRequestReviewComment = { id = vars.commentId },
    } } })
  end
  local init = require("gh_review")
  local original_refresh = init.refresh_threads
  local refresh_count = 0
  init.refresh_threads = function() refresh_count = refresh_count + 1 end

  vim.fn.maparg("<C-d>", "n", false, true).callback()
  vim.ui.select = original_select
  api.graphql = original_graphql
  init.refresh_threads = original_refresh

  h.assert_equal(require("gh_review.graphql").MUTATION_DELETE_REVIEW_COMMENT, captured.mutation)
  h.assert_equal("comment_5", captured.vars.commentId)
  h.assert_equal(1, refresh_count)
  h.assert_equal(-1, state.get_thread_bufnr(), "successful deletion closes the editor")
end)

h.run_test("Thread: reply separator text follows configured keys", function()
  local config = require("gh_review.config")
  config.reset()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())

  thread.open_new("src/main.ts", 10, 10, "RIGHT", "")
  local bufnr = state.get_thread_bufnr()
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  h.assert_match("Ctrl%-S to submit", text, "default renders <C-s> as Ctrl-S")
  h.assert_match("Ctrl%-R to resolve", text)
  h.assert_match("Ctrl%-Q to cancel", text)
  thread.close_thread_buffer()

  config.setup({ keymaps = { thread = { submit = "<leader>s", resolve = false } } })
  thread.open_new("src/main.ts", 10, 10, "RIGHT", "")
  bufnr = state.get_thread_bufnr()
  text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  h.assert_match("<leader>s to submit", text, "remapped key shown verbatim")
  h.assert_true(text:find("to resolve") == nil, "disabled action omitted from the hint")
  h.assert_match("Reply below", text, "separator shape preserved for syntax matching")
  thread.close_thread_buffer()

  config.reset()
end)

h.run_test("Thread: keymaps honour configuration", function()
  local config = require("gh_review.config")
  config.reset()
  config.setup({ keymaps = { thread = { resolve = "Z", delete_comment = "X", close_insert = false } } })

  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  thread.open_new("src/main.ts", 10, 10, "RIGHT", "")
  local bufnr = state.get_thread_bufnr()

  local function mapped(mode, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      if m.lhs == lhs then return m end
    end
    return nil
  end

  h.assert_true(mapped("n", "Z") ~= nil, "resolve remapped")
  h.assert_true(mapped("n", "X") ~= nil, "delete comment remapped")
  h.assert_true(mapped("n", "q") ~= nil, "close default intact")
  h.assert_true(mapped("i", "<C-Q>") == nil, "close_insert disabled in insert mode")
  h.assert_true(mapped("i", "<C-S>") ~= nil, "submit still bound in insert mode")

  thread.close_thread_buffer()
  config.reset()
end)

h.write_results("/tmp/gh_review_test_thread.txt")
