-- Tests for the changed-files picker and file navigation.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local files = require("gh_review.files")

local function window_title(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then return title end
  local parts = {}
  for _, chunk in ipairs(title or {}) do parts[#parts + 1] = chunk[1] end
  return table.concat(parts)
end

h.run_test("Files picker: Open creates floating buffer with correct content", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.open()

  local bufnr = state.get_files_bufnr()
  h.assert_true(bufnr ~= -1, "files bufnr should be set")
  h.assert_true(vim.fn.bufexists(bufnr) == 1, "files buffer should exist")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  h.assert_equal(3, #lines, "picker has one row per changed file")
  h.assert_match("src/new_file.ts", lines[1])
  h.assert_match("src/existing.ts", lines[2])
  h.assert_match("src/old_file.ts", lines[3])
  h.assert_match("A", lines[1])
  h.assert_match("M", lines[2])
  h.assert_match("D", lines[3])
  h.assert_match("%[2 threads%]", lines[1])
  h.assert_match("%[2 threads%]", lines[2])

  local winid = vim.fn.bufwinid(bufnr)
  h.assert_equal("editor", vim.api.nvim_win_get_config(winid).relative)
  h.assert_match("PR #42", window_title(winid))
  h.assert_match("Add feature X", window_title(winid))
  h.assert_match("Files %(3%)", window_title(winid))

  files.close()
end)

h.run_test("Files picker: Toggle opens and closes", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.toggle()
  local bufnr = state.get_files_bufnr()
  h.assert_true(bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1, "buffer should exist after toggle on")
  h.assert_true(vim.fn.bufwinid(bufnr) ~= -1, "buffer should be visible after toggle on")

  files.toggle()
  h.assert_false(vim.api.nvim_buf_is_valid(bufnr), "picker buffer is deleted after toggle off")
  h.assert_equal(-1, state.get_files_bufnr())

  files.toggle()
  bufnr = state.get_files_bufnr()
  h.assert_true(vim.fn.bufwinid(bufnr) ~= -1, "buffer should be visible after second toggle on")

  files.close()
end)

h.run_test("Files picker: buffer options are correct", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.open()
  local bufnr = state.get_files_bufnr()

  h.assert_equal("nofile", vim.bo[bufnr].buftype)
  h.assert_equal("wipe", vim.bo[bufnr].bufhidden)
  h.assert_false(vim.bo[bufnr].swapfile)
  h.assert_false(vim.bo[bufnr].modifiable)
  h.assert_equal("gh-review-files", vim.bo[bufnr].filetype)

  files.close()
end)

h.run_test("Files picker: additions and deletions shown", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.open()
  local bufnr = state.get_files_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  h.assert_match("%+50", lines[1])
  h.assert_match("%-0", lines[1])
  h.assert_match("%+10", lines[2])
  h.assert_match("%-5", lines[2])
  h.assert_match("%+0", lines[3])
  h.assert_match("%-30", lines[3])

  files.close()
end)

h.run_test("Files picker: selection closes picker and opens diff", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  files.open()
  local bufnr = state.get_files_bufnr()
  local winid = vim.fn.bufwinid(bufnr)

  local opened_path
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function(path) opened_path = path end }
  vim.api.nvim_win_set_cursor(winid, { 2, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  package.loaded["gh_review.diff"] = original_diff

  h.assert_equal("src/existing.ts", opened_path)
  h.assert_false(vim.api.nvim_buf_is_valid(bufnr), "selection closes and deletes the picker")
end)

h.run_test("Files picker: Rerender updates content", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.open()
  local bufnr = state.get_files_bufnr()

  state.set_thread("thread_extra", { id = "thread_extra", isResolved = false, isOutdated = false, line = 1, startLine = vim.NIL, diffSide = "RIGHT", path = "src/old_file.ts", comments = { nodes = {} } })

  files.rerender()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  h.assert_match("%[1 thread%]", lines[3])

  files.close()
end)

h.run_test("Files picker: selected commit range is visible in the title", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_merge_base_oid("merge000")
  state.set_diff_base_oid("selected123456")
  files.open()

  local winid = vim.fn.bufwinid(state.get_files_bufnr())
  h.assert_match("Files after selected", window_title(winid))
  files.close()
end)

h.run_test("Files picker: Close leaves existing layout intact", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  vim.cmd("aboveleft vnew")
  local normal_windows = #vim.api.nvim_tabpage_list_wins(0)
  files.open()
  local files_bufnr = state.get_files_bufnr()
  h.assert_equal(normal_windows + 1, #vim.api.nvim_tabpage_list_wins(0), "picker adds only a float")

  files.close()
  h.assert_equal(normal_windows, #vim.api.nvim_tabpage_list_wins(0), "closing float preserves normal splits")
  h.assert_false(vim.api.nvim_buf_is_valid(files_bufnr))
  vim.cmd("only")
end)

h.run_test("Files picker: gf keymap closes the picker", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  files.open()
  local bufnr = state.get_files_bufnr()
  h.assert_true(vim.fn.bufwinid(bufnr) ~= -1, "files window should be visible")

  local winid = vim.fn.bufwinid(bufnr)
  vim.fn.win_gotoid(winid)
  vim.cmd("normal gf")

  h.assert_false(vim.api.nvim_buf_is_valid(bufnr), "files picker should be deleted after gf")
end)

h.run_test("Files picker: all change type flags rendered correctly", function()
  state.reset()
  state.set_pr(fixtures.mock_all_change_types_pr_data())
  state.set_threads({})
  state.set_repo_info("test-owner", "test-repo")

  files.open()
  local bufnr = state.get_files_bufnr()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  h.assert_match("%sA%s", lines[1], "ADDED should show A flag")
  h.assert_match("%sM%s", lines[2], "MODIFIED should show M flag")
  h.assert_match("%sD%s", lines[3], "DELETED should show D flag")
  h.assert_match("%sR%s", lines[4], "RENAMED should show R flag")
  h.assert_match("%sC%s", lines[5], "COPIED should show C flag")

  files.close()
end)


h.run_test("Files picker: viewed state hydrated from viewerViewedState", function()
  state.reset()
  local data = fixtures.mock_pr_data()
  data.data.repository.pullRequest.files.nodes[2].viewerViewedState = "VIEWED"
  state.set_pr(data)
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")

  h.assert_true(state.is_file_checked("src/existing.ts"), "VIEWED file should be checked")
  h.assert_false(state.is_file_checked("src/new_file.ts"), "non-VIEWED file should be unchecked")

  files.close()
end)

-- Invoke the buffer's <Space> mapping callback directly (avoids termcode
-- feedkeys issues in headless mode).
local function press_space(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  vim.fn.win_gotoid(winid)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == " " and m.callback then
      m.callback()
      return
    end
  end
  error("no <Space> mapping found on files buffer")
end

-- Toggle the file on `row` via a stubbed api.graphql. With `response` the
-- callback fires immediately; without it the callback is returned so the test
-- can resolve it later to exercise in-flight ordering.
local function toggle_file_row(row, response)
  local api = require("gh_review.api")
  local original = api.graphql
  local captured = {}
  api.graphql = function(_, vars, callback)
    captured.vars = vars
    captured.callback = callback
    if response then callback(response.result, response.err) end
  end
  local bufnr = state.get_files_bufnr()
  vim.api.nvim_win_set_cursor(vim.fn.bufwinid(bufnr), { row, 0 })
  press_space(bufnr)
  api.graphql = original
  return captured
end
h.run_test("Files picker: toggle marks file viewed and persists on success", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")
  files.open()

  local captured = toggle_file_row(1, { result = { data = { markFileAsViewed = { pullRequest = { id = "PR_abc123" } } } } })

  h.assert_equal("src/new_file.ts", captured.vars.path, "mutation sent for the file under cursor")
  h.assert_equal("PR_abc123", captured.vars.pullRequestId, "mutation includes PR id")
  h.assert_true(state.is_file_checked("src/new_file.ts"), "file stays checked after successful mutation")

  local lines = vim.api.nvim_buf_get_lines(state.get_files_bufnr(), 0, -1, false)
  h.assert_match("^%[x%]", lines[1], "checkbox shows checked after success")
  h.assert_match("^%[ %]", lines[2], "other files stay unchecked")

  files.close()
end)

h.run_test("Files picker: toggle reverts optimistic state on failure", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")
  files.open()

  toggle_file_row(1, { result = nil, err = "GraphQL error: boom" })

  h.assert_false(state.is_file_checked("src/new_file.ts"), "failed mutation reverts to unchecked")
  local lines = vim.api.nvim_buf_get_lines(state.get_files_bufnr(), 0, -1, false)
  h.assert_match("^%[ %]", lines[1], "checkbox shows unchecked after failure")

  files.close()
end)

h.run_test("Files picker: stale in-flight failure does not clobber newer toggle", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")
  files.open()

  -- Leave the first toggle's request in flight, then toggle again before it
  -- resolves; the stale first failure must not clobber the newer state.
  local first = toggle_file_row(1)
  h.assert_true(state.is_file_checked("src/new_file.ts"), "file checked after first toggle")

  toggle_file_row(1)
  h.assert_false(state.is_file_checked("src/new_file.ts"), "file unchecked after second toggle")

  first.callback(nil, "boom")
  h.assert_false(state.is_file_checked("src/new_file.ts"), "stale failure must not clobber newer state")

  files.close()
end)

h.run_test("Files picker: failed thread refresh keeps existing threads", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_repo_info("test-owner", "test-repo")
  files.open()

  local before = vim.tbl_count(state.get_threads())
  h.assert_true(before > 0, "precondition: threads exist before refresh")

  -- A failed refresh must not wipe the thread list or report success.
  local api = require("gh_review.api")
  local original = api.graphql
  api.graphql = function(_, _, callback) callback(nil, "GraphQL error: boom") end
  require("gh_review").refresh_threads()
  api.graphql = original

  h.assert_equal(before, vim.tbl_count(state.get_threads()), "threads preserved after failed refresh")

  files.close()
end)

h.run_test("Files picker: keymaps honour configuration", function()
  local config = require("gh_review.config")

  -- Start from a fresh buffer. files.open() reuses an existing one, which
  -- would still carry the mappings applied under the previous configuration --
  -- the documented limitation of calling setup() twice mid-session.
  local stale = vim.fn.bufnr("gh-review://files")
  if stale ~= -1 then vim.cmd("silent! bwipeout! " .. stale) end

  config.reset()
  config.setup({ keymaps = { files = { toggle_viewed = "v", refresh = false } } })

  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_repo_info("test-owner", "test-repo")
  files.open()

  local bufnr = state.get_files_bufnr()
  local function mapped(mode, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      if m.lhs == lhs then return m end
    end
    return nil
  end

  h.assert_true(mapped("n", "v") ~= nil, "toggle_viewed remapped to v")
  h.assert_true(mapped("n", " ") == nil, "default <Space> no longer mapped")
  h.assert_true(mapped("n", "R") == nil, "refresh disabled")
  h.assert_true(mapped("n", "q") ~= nil, "untouched default still mapped")

  files.close()
  config.reset()
end)

h.run_test("Next file advances without changing viewed state or skipping viewed files", function()
  state.reset()
  local data = fixtures.mock_pr_data()
  data.data.repository.pullRequest.files.nodes[2].viewerViewedState = "VIEWED"
  state.set_pr(data)
  state.set_diff_path("src/new_file.ts")

  local opened_path
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function(path) opened_path = path end }

  files.next_file()

  package.loaded["gh_review.diff"] = original_diff
  h.assert_false(state.is_file_checked("src/new_file.ts"))
  h.assert_equal("src/existing.ts", opened_path, "already-viewed next file is not skipped")
end)

h.run_test("Next file leaves the final file unviewed and stops", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_diff_path("src/old_file.ts")

  local open_count = 0
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function() open_count = open_count + 1 end }

  files.next_file()

  package.loaded["gh_review.diff"] = original_diff
  h.assert_false(state.is_file_checked("src/old_file.ts"))
  h.assert_equal(0, open_count, "final file does not wrap")
end)

h.run_test("Previous file moves backward without changing viewed state or skipping", function()
  state.reset()
  local data = fixtures.mock_pr_data()
  data.data.repository.pullRequest.files.nodes[2].viewerViewedState = "VIEWED"
  state.set_pr(data)
  state.set_diff_path("src/old_file.ts")

  local opened_path
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function(path) opened_path = path end }

  files.prev_file()

  package.loaded["gh_review.diff"] = original_diff
  h.assert_false(state.is_file_checked("src/old_file.ts"))
  h.assert_equal("src/existing.ts", opened_path, "already-viewed previous file is not skipped")
end)

h.run_test("Previous file leaves the first file unviewed and stops", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_diff_path("src/new_file.ts")

  local open_count = 0
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function() open_count = open_count + 1 end }

  files.prev_file()

  package.loaded["gh_review.diff"] = original_diff
  h.assert_false(state.is_file_checked("src/new_file.ts"))
  h.assert_equal(0, open_count, "first file does not wrap")
end)

h.run_test("GHReviewNextFile command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewNextFile"))
end)

h.run_test("GHReviewPrevFile command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewPrevFile"))
end)

h.run_test("Current file opens its review diff and preserves cursor", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_diff_path("src/other.lua")
  local root = vim.fs.root(vim.fn.getcwd(), ".git")
  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(source, root .. "/src/current_file_command_test.lua")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "one", "0123456789", "three" })
  vim.cmd("buffer " .. source)
  vim.api.nvim_win_set_cursor(0, { 2, 6 })

  local opened_path
  local right
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function(path, callback)
    opened_path = path
    right = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(right, 0, -1, false, { "head one", "abcdefghij", "head three" })
    vim.cmd("buffer " .. right)
    callback(-1, right)
  end }

  files.open_current_file()

  package.loaded["gh_review.diff"] = original_diff
  h.assert_equal("src/current_file_command_test.lua", opened_path)
  local cursor = vim.api.nvim_win_get_cursor(0)
  h.assert_equal(2, cursor[1])
  h.assert_equal(6, cursor[2])
  vim.cmd("bwipeout! " .. source)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Current file does nothing when its review diff is already open", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  local root = vim.fs.root(vim.fn.getcwd(), ".git")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, root .. "/src/already_reviewed.lua")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
  vim.cmd("buffer " .. bufnr)
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  state.set_diff_path("src/already_reviewed.lua")

  local open_count = 0
  local original_diff = package.loaded["gh_review.diff"]
  package.loaded["gh_review.diff"] = { open = function() open_count = open_count + 1 end }
  files.open_current_file()
  package.loaded["gh_review.diff"] = original_diff

  h.assert_equal(0, open_count)
  local cursor = vim.api.nvim_win_get_cursor(0)
  h.assert_equal(2, cursor[1])
  h.assert_equal(1, cursor[2])
  vim.cmd("bwipeout! " .. bufnr)
end)

h.run_test("GHReviewCurrentFile command is registered", function()
  h.assert_equal(2, vim.fn.exists(":GHReviewCurrentFile"))
end)

h.write_results("/tmp/gh_review_test_ui.txt")
