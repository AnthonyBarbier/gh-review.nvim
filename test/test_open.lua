-- Tests for URL parsing and argument handling in open().

local h = require("test.helpers")
local fixtures = require("test.fixtures")

-- Helper: given a string argument, return a table with owner, name, number
-- using the same parsing logic as open().
local function parse_pr_url(arg)
  local o, n, num = arg:match("github%.com/([^/]+)/([^/]+)/pull/(%d+)")
  if o then
    return { owner = o, name = n, number = tonumber(num) }
  else
    return { owner = "", name = "", number = tonumber(arg) or 0 }
  end
end

local function parse_pr_number(arg)
  return parse_pr_url(arg).number
end

h.run_test("Parse plain number", function()
  h.assert_equal(123, parse_pr_number("123"))
  h.assert_equal(1, parse_pr_number("1"))
  h.assert_equal(99999, parse_pr_number("99999"))
end)

h.run_test("Parse GitHub PR URL", function()
  h.assert_equal(42, parse_pr_number("https://github.com/owner/repo/pull/42"))
  h.assert_equal(39880, parse_pr_number("https://github.com/mdn/content/pull/39880"))
end)

h.run_test("Parse URL with trailing path segments", function()
  h.assert_equal(100, parse_pr_number("https://github.com/owner/repo/pull/100/files"))
  h.assert_equal(100, parse_pr_number("https://github.com/owner/repo/pull/100/commits"))
end)

h.run_test("Parse URL with query string or fragment", function()
  h.assert_equal(55, parse_pr_number("https://github.com/owner/repo/pull/55?diff=split"))
  h.assert_equal(55, parse_pr_number("https://github.com/owner/repo/pull/55#discussion"))
end)

h.run_test("Invalid input returns zero", function()
  h.assert_equal(0, parse_pr_number("not-a-number"))
  h.assert_equal(0, parse_pr_number(""))
  h.assert_equal(0, parse_pr_number("https://github.com/owner/repo"))
end)

h.run_test("Parse URL extracts owner and repo", function()
  local result = parse_pr_url("https://github.com/owner/repo/pull/42")
  h.assert_equal("owner", result.owner)
  h.assert_equal("repo", result.name)
  h.assert_equal(42, result.number)
end)

h.run_test("Parse URL with org/repo names", function()
  local result = parse_pr_url("https://github.com/mdn/content/pull/39880")
  h.assert_equal("mdn", result.owner)
  h.assert_equal("content", result.name)
  h.assert_equal(39880, result.number)
end)

h.run_test("Plain number has empty owner and name", function()
  local result = parse_pr_url("123")
  h.assert_equal("", result.owner)
  h.assert_equal("", result.name)
  h.assert_equal(123, result.number)
end)

h.run_test("Parse URL with files tab and diff anchor", function()
  local result = parse_pr_url("https://github.com/mdn/content/pull/42276/files#diff-fcec8db9553a615a137defcf2624ae9937e6ebab9835a408d9f2f50a4e734864")
  h.assert_equal("mdn", result.owner)
  h.assert_equal("content", result.name)
  h.assert_equal(42276, result.number)
end)

h.run_test("Parse URL with commits tab and SHA", function()
  local result = parse_pr_url("https://github.com/mdn/content/pull/42276/commits/d66a80fd8b932fc573bd57f1c76ad07538e74e0e")
  h.assert_equal("mdn", result.owner)
  h.assert_equal("content", result.name)
  h.assert_equal(42276, result.number)
end)

h.run_test("Merge base uses immutable PR OIDs when branch refs are unavailable", function()
  local api = require("gh_review.api")
  local config = require("gh_review.config")
  local files = require("gh_review.files")
  local review = require("gh_review")
  local state = require("gh_review.state")
  local original_graphql = api.graphql
  local original_run_async = api.run_async
  local original_files_open = files.open
  local original_system = vim.system
  local system_commands = {}
  local compare_endpoint = ""

  state.reset()
  config.setup({ checkout = "never" })
  vim.system = function(command)
    system_commands[#system_commands + 1] = command
    return {
      wait = function()
        if command[2] == "remote" then
          return { code = 0, stdout = "https://github.com/testowner/testrepo.git\n" }
        end
        return { code = 1, stdout = "", stderr = "missing local object" }
      end,
    }
  end
  api.graphql = function(_, _, callback) callback(fixtures.mock_pr_data()) end
  api.run_async = function(command, callback)
    compare_endpoint = command[2]
    callback(vim.json.encode({ merge_base_commit = { sha = "merge123" } }), "")
  end
  files.open = function() end

  review.open("https://github.com/testowner/testrepo/pull/42")

  vim.system = original_system
  api.graphql = original_graphql
  api.run_async = original_run_async
  files.open = original_files_open
  config.setup({})

  -- Branch names may contain slashes, may not have local tracking refs, and
  -- are ambiguous for fork PRs.  The GraphQL PR OIDs identify the exact pair
  -- of commits whose merge base defines GitHub's full-PR diff.
  h.assert_true(vim.deep_equal(
    { "git", "merge-base", "aaa111", "bbb222" }, system_commands[2]))
  h.assert_equal("/repos/testowner/testrepo/compare/aaa111...bbb222", compare_endpoint)
  h.assert_equal("merge123", state.get_merge_base_oid())
end)

h.write_results("/tmp/gh_review_test_open.txt")
