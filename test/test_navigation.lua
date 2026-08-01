-- Tests for diff navigation helpers and thread opening logic.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local diff = require("gh_review.diff")
local thread = require("gh_review.thread")

local function setup_buffer(name, num_lines)
  local bufnr = vim.fn.bufnr(name, true)
  vim.cmd("buffer " .. bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  local lines = {}
  for i = 1, num_lines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.wo.signcolumn = "yes"
  return bufnr
end

-- Helper: get extmarks that have sign_text, simulating the old sign_getplaced API.
local function get_extmark_signs(bufnr)
  local ns = require("gh_review.state").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local signs = {}
  for _, m in ipairs(marks) do
    local details = m[4] or {}
    if details.sign_text then
      signs[#signs + 1] = {
        lnum = m[2] + 1,
        name = details.sign_hl_group,
        sign_text = details.sign_text,
      }
    end
  end
  return signs
end

h.run_test("Signs placed on both sides for mixed-side threads", function()
  state.reset()

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/sides.ts", 50)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/sides.ts", 50)
  state.set_right_bufnr(right)
  state.set_diff_path("src/sides.ts")

  state.set_threads({
    { id = "s1", isResolved = false, isOutdated = false, line = 10, originalLine = 10, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "LEFT", path = "src/sides.ts", comments = { nodes = { { id = "c1", body = "x", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
    { id = "s2", isResolved = false, isOutdated = false, line = 20, originalLine = 20, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/sides.ts", comments = { nodes = { { id = "c2", body = "y", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
    { id = "s3", isResolved = false, isOutdated = false, line = 30, originalLine = 30, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "LEFT", path = "src/sides.ts", comments = { nodes = { { id = "c3", body = "z", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
  })

  diff.refresh_signs()

  local left_signs = get_extmark_signs(left)
  local right_signs = get_extmark_signs(right)
  table.sort(left_signs, function(a, b) return a.lnum < b.lnum end)

  h.assert_equal(2, #left_signs, "LEFT should have 2 signs")
  h.assert_equal(10, left_signs[1].lnum)
  h.assert_equal(30, left_signs[2].lnum)

  h.assert_equal(1, #right_signs, "RIGHT should have 1 sign")
  h.assert_equal(20, right_signs[1].lnum)

  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("RefreshSigns clears old signs before placing new ones", function()
  state.reset()

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/refresh.ts", 50)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/refresh.ts", 50)
  state.set_right_bufnr(right)
  state.set_diff_path("src/refresh.ts")

  state.set_threads({
    { id = "r1", isResolved = false, isOutdated = false, line = 5, originalLine = 5, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/refresh.ts", comments = { nodes = { { id = "c1", body = "x", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
    { id = "r2", isResolved = false, isOutdated = false, line = 15, originalLine = 15, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/refresh.ts", comments = { nodes = { { id = "c2", body = "y", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
    { id = "r3", isResolved = false, isOutdated = false, line = 25, originalLine = 25, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/refresh.ts", comments = { nodes = { { id = "c3", body = "z", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
  })
  diff.refresh_signs()
  h.assert_equal(3, #get_extmark_signs(right))

  state.set_threads({
    { id = "r1", isResolved = false, isOutdated = false, line = 5, originalLine = 5, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/refresh.ts", comments = { nodes = { { id = "c1", body = "x", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
  })
  diff.refresh_signs()

  local signs = get_extmark_signs(right)
  h.assert_equal(1, #signs, "should have 1 sign after refresh")
  h.assert_equal(5, signs[1].lnum)

  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Thread opened by id shows correct buffer metadata", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/new_file.ts", 50)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/new_file.ts", 50)
  state.set_right_bufnr(right)
  state.set_diff_path("src/new_file.ts")

  thread.open("thread_1")

  local thread_bufnr = state.get_thread_bufnr()
  h.assert_true(thread_bufnr ~= -1, "thread buffer should be open")
  h.assert_equal("thread_1", vim.b[thread_bufnr].gh_review_thread_id)
  h.assert_equal("src/new_file.ts", vim.b[thread_bufnr].gh_review_path)
  h.assert_equal(10, vim.b[thread_bufnr].gh_review_line)

  thread.close_thread_buffer()
  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Threads for different file do not get signs", function()
  state.reset()

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/other.ts", 50)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/other.ts", 50)
  state.set_right_bufnr(right)
  state.set_diff_path("src/other.ts")

  state.set_threads({
    { id = "t1", isResolved = false, isOutdated = false, line = 10, originalLine = 10, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/different.ts", comments = { nodes = { { id = "c1", body = "x", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
  })

  diff.refresh_signs()

  local right_signs = get_extmark_signs(right)
  h.assert_equal(0, #right_signs, "should have no signs for different file")

  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Signs for threads with line: 0 are skipped", function()
  state.reset()

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/zero.ts", 50)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/zero.ts", 50)
  state.set_right_bufnr(right)
  state.set_diff_path("src/zero.ts")

  state.set_threads({
    { id = "z1", isResolved = false, isOutdated = false, line = 0, originalLine = 0, startLine = vim.NIL, originalStartLine = vim.NIL, diffSide = "RIGHT", path = "src/zero.ts", comments = { nodes = { { id = "c1", body = "x", author = { login = "a" }, createdAt = "2025-01-01T00:00:00Z", pullRequestReview = { id = "r1", state = "COMMENTED" } } } } },
  })

  diff.refresh_signs()

  local right_signs = get_extmark_signs(right)
  h.assert_equal(0, #right_signs, "should skip thread with line: 0")

  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Diff keymaps have desc fields", function()
  state.reset()

  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/desc.ts", 20)
  state.set_right_bufnr(right)
  state.set_diff_path("src/desc.ts")

  -- Use the real helper so this test cannot drift from the module.
  local config = require("gh_review.config")
  config.reset()
  config.apply_keymaps(right, "diff", {
    thread_open = { { "n", function() end, "Open review thread" } },
  })
  local maps = vim.api.nvim_buf_get_keymap(right, "n")
  local gt_map
  for _, m in ipairs(maps) do
    if m.lhs == "gt" then
      gt_map = m
      break
    end
  end
  h.assert_true(gt_map ~= nil, "gt keymap should exist")
  h.assert_equal("Open review thread", gt_map.desc)

  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Files list keymaps have desc fields", function()
  state.reset()

  local bufnr = vim.fn.bufnr("gh-review://files-desc-test", true)
  vim.cmd("buffer " .. bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false

  local config = require("gh_review.config")
  config.reset()
  config.apply_keymaps(bufnr, "files", {
    open    = { { "n", function() end, "Open diff" } },
    refresh = { { "n", function() end, "Refresh threads" } },
  })

  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local cr_desc, r_desc
  for _, m in ipairs(maps) do
    if m.lhs == "<CR>" then cr_desc = m.desc end
    if m.lhs == "R" then r_desc = m.desc end
  end
  h.assert_equal("Open diff", cr_desc)
  h.assert_equal("Refresh threads", r_desc)

  vim.cmd("bwipeout! " .. bufnr)
end)

h.run_test("Thread keymaps have desc fields", function()
  state.reset()
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())

  vim.cmd("enew")
  local left = setup_buffer("gh-review://LEFT/src/desc_thread.ts", 30)
  state.set_left_bufnr(left)
  vim.cmd("enew")
  local right = setup_buffer("gh-review://RIGHT/src/desc_thread.ts", 30)
  state.set_right_bufnr(right)
  state.set_diff_path("src/new_file.ts")

  local thread_mod = require("gh_review.thread")
  thread_mod.open("thread_1")
  local bufnr = state.get_thread_bufnr()

  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local descs = {}
  for _, m in ipairs(maps) do
    if m.desc then descs[m.lhs] = m.desc end
  end

  h.assert_equal("Submit reply", descs["<C-S>"])
  h.assert_equal("Toggle resolved", descs["<C-R>"])
  h.assert_equal("Close thread", descs["q"])

  thread_mod.close_thread_buffer()
  vim.cmd("bwipeout! " .. left)
  vim.cmd("bwipeout! " .. right)
end)

h.run_test("Diff: clear_keymaps removes every applied mapping", function()
  local config = require("gh_review.config")
  config.reset()
  config.setup({ keymaps = { diff = { thread_open = "Z", preview = false } } })

  local ACTIONS = {
    thread_open = { { "n", function() end, "Open review thread" } },
    comment     = { { "n", function() end, "New comment" },
                    { "x", function() end, "New comment (range)" } },
    preview     = { { "n", function() end, "Preview thread" } },
  }
  local bufnr = vim.api.nvim_create_buf(false, true)

  local function count()
    return #vim.api.nvim_buf_get_keymap(bufnr, "n") + #vim.api.nvim_buf_get_keymap(bufnr, "x")
  end

  h.assert_equal(0, count(), "buffer starts clean")
  config.apply_keymaps(bufnr, "diff", ACTIONS)
  h.assert_equal(3, count(), "thread_open + comment in two modes; preview skipped")
  config.clear_keymaps(bufnr, "diff", ACTIONS)
  h.assert_equal(0, count(), "clear removes everything apply set, at configured keys")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  config.reset()
end)

h.run_test("Diff: close_diff tears down remapped keys, not hardcoded ones", function()
  -- The teardown path that matters: on a local checkout the head buffer is a
  -- real working-tree file that outlives the diff, so our buffer-local maps
  -- must come off it. Teardown has to follow configuration, or a remapped key
  -- is left shadowing whatever the user actually bound it to.
  local config = require("gh_review.config")
  config.reset()
  config.setup({ keymaps = { diff = { close = "Z" } } })

  state.reset()
  local tmpfile = "/tmp/gh_review_test_teardown.lua"
  vim.fn.writefile({ "local a = 1", "return a" }, tmpfile)
  vim.cmd("edit " .. tmpfile)
  local rbuf = vim.api.nvim_get_current_buf()

  config.apply_keymaps(rbuf, "diff", {
    close       = { { "n", function() end, "Close diff" } },
    thread_open = { { "n", function() end, "Open review thread" } },
  })

  local function mapped(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(rbuf, "n")) do
      if m.lhs == lhs then return true end
    end
    return false
  end

  h.assert_true(mapped("Z"), "remapped close applied at Z")
  h.assert_true(mapped("gt"), "default thread_open applied at gt")

  state.set_right_bufnr(rbuf)
  state.set_diff_path("gh_review_test_teardown.lua")
  state.set_local_checkout(true)
  diff.close_diff()

  h.assert_false(mapped("Z"), "remapped close removed from the surviving real file")
  h.assert_false(mapped("gt"), "default mapping removed too")

  vim.fn.delete(tmpfile)
  pcall(vim.cmd, "bwipeout! " .. rbuf)
  config.reset()
end)

h.write_results("/tmp/gh_review_test_navigation.txt")
