-- Tests for lua/gh_review/graphql.lua

local h = require("test.helpers")
local graphql = require("gh_review.graphql")

local constants = {
  { name = "QUERY_PR_DETAILS", val = graphql.QUERY_PR_DETAILS },
  { name = "QUERY_REVIEW_THREADS", val = graphql.QUERY_REVIEW_THREADS },
  { name = "QUERY_PR_COMMITS", val = graphql.QUERY_PR_COMMITS },
  { name = "QUERY_MY_LAST_REVIEW", val = graphql.QUERY_MY_LAST_REVIEW },
  { name = "QUERY_VIEWER_LOGIN", val = graphql.QUERY_VIEWER_LOGIN },
  { name = "QUERY_OPEN_PULL_REQUESTS", val = graphql.QUERY_OPEN_PULL_REQUESTS },
  { name = "MUTATION_START_REVIEW", val = graphql.MUTATION_START_REVIEW },
  { name = "MUTATION_SUBMIT_REVIEW", val = graphql.MUTATION_SUBMIT_REVIEW },
  { name = "MUTATION_ADD_REVIEW_THREAD", val = graphql.MUTATION_ADD_REVIEW_THREAD },
  { name = "MUTATION_ADD_REVIEW_COMMENT", val = graphql.MUTATION_ADD_REVIEW_COMMENT },
  { name = "MUTATION_UPDATE_REVIEW_COMMENT", val = graphql.MUTATION_UPDATE_REVIEW_COMMENT },
  { name = "MUTATION_DELETE_REVIEW_COMMENT", val = graphql.MUTATION_DELETE_REVIEW_COMMENT },
  { name = "MUTATION_RESOLVE_THREAD", val = graphql.MUTATION_RESOLVE_THREAD },
  { name = "MUTATION_UNRESOLVE_THREAD", val = graphql.MUTATION_UNRESOLVE_THREAD },
  { name = "MUTATION_DELETE_REVIEW", val = graphql.MUTATION_DELETE_REVIEW },
  { name = "MUTATION_CREATE_AND_SUBMIT_REVIEW", val = graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW },
}

h.run_test("All GraphQL constants are strings", function()
  for _, c in ipairs(constants) do
    h.assert_equal("string", type(c.val), c.name .. " should be a string")
  end
end)

h.run_test("All GraphQL constants are non-empty", function()
  for _, c in ipairs(constants) do
    h.assert_true(#c.val > 0, c.name .. " should be non-empty")
  end
end)

h.run_test("QUERY_PR_DETAILS contains expected fragments", function()
  local q = graphql.QUERY_PR_DETAILS
  h.assert_match("pullRequest", q)
  h.assert_match("reviewThreads", q)
  h.assert_match("files", q)
  h.assert_match("reviews", q)
  h.assert_match("baseRefName", q)
  h.assert_match("headRefOid", q)
end)

h.run_test("QUERY_REVIEW_THREADS contains reviewThreads", function()
  h.assert_match("reviewThreads", graphql.QUERY_REVIEW_THREADS)
  h.assert_match("comments", graphql.QUERY_REVIEW_THREADS)
  h.assert_match("pullRequestReview", graphql.QUERY_REVIEW_THREADS)
end)

h.run_test("QUERY_PR_COMMITS contains pagination and commit metadata", function()
  local q = graphql.QUERY_PR_COMMITS
  h.assert_match("commits", q)
  h.assert_match("pageInfo", q)
  h.assert_match("endCursor", q)
  h.assert_match("messageHeadline", q)
end)

h.run_test("QUERY_MY_LAST_REVIEW contains viewer and backward review pagination", function()
  local q = graphql.QUERY_MY_LAST_REVIEW
  h.assert_match("viewer", q)
  h.assert_match("reviews", q)
  h.assert_match("submittedAt", q)
  h.assert_match("hasPreviousPage", q)
  h.assert_match("startCursor", q)
end)

h.run_test("QUERY_OPEN_PULL_REQUESTS filters viewer reviews and paginates", function()
  local q = graphql.QUERY_OPEN_PULL_REQUESTS
  h.assert_match("states: OPEN", q)
  h.assert_match("UPDATED_AT", q)
  h.assert_match("author: %$viewer", q)
  h.assert_match("labels", q)
  h.assert_match("name", q)
  h.assert_match("hasNextPage", q)
  h.assert_match("totalCount", q)
end)

h.run_test("Mutations contain mutation keyword", function()
  h.assert_match("mutation", graphql.MUTATION_START_REVIEW)
  h.assert_match("mutation", graphql.MUTATION_SUBMIT_REVIEW)
  h.assert_match("mutation", graphql.MUTATION_ADD_REVIEW_THREAD)
  h.assert_match("mutation", graphql.MUTATION_ADD_REVIEW_COMMENT)
  h.assert_match("mutation", graphql.MUTATION_UPDATE_REVIEW_COMMENT)
  h.assert_match("mutation", graphql.MUTATION_DELETE_REVIEW_COMMENT)
  h.assert_match("mutation", graphql.MUTATION_RESOLVE_THREAD)
  h.assert_match("mutation", graphql.MUTATION_UNRESOLVE_THREAD)
  h.assert_match("mutation", graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW)
end)

h.run_test("Pending comment mutations target a review comment ID", function()
  h.assert_match("pullRequestReviewCommentId", graphql.MUTATION_UPDATE_REVIEW_COMMENT)
  h.assert_match("%$body", graphql.MUTATION_UPDATE_REVIEW_COMMENT)
  h.assert_match("deletePullRequestReviewComment", graphql.MUTATION_DELETE_REVIEW_COMMENT)
  h.assert_match("id: %$commentId", graphql.MUTATION_DELETE_REVIEW_COMMENT)
end)

h.run_test("Queries contain query keyword", function()
  h.assert_match("query", graphql.QUERY_PR_DETAILS)
  h.assert_match("query", graphql.QUERY_REVIEW_THREADS)
  h.assert_match("query", graphql.QUERY_PR_COMMITS)
  h.assert_match("query", graphql.QUERY_MY_LAST_REVIEW)
  h.assert_match("query", graphql.QUERY_VIEWER_LOGIN)
  h.assert_match("query", graphql.QUERY_OPEN_PULL_REQUESTS)
end)

h.run_test("MUTATION_ADD_REVIEW_THREAD has line/side/path params", function()
  local m = graphql.MUTATION_ADD_REVIEW_THREAD
  h.assert_match("%$path", m)
  h.assert_match("%$line", m)
  h.assert_match("%$side", m)
  h.assert_match("%$body", m)
end)

h.run_test("MUTATION_CREATE_AND_SUBMIT_REVIEW has event and pullRequestId params", function()
  local m = graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW
  h.assert_match("%$pullRequestId", m)
  h.assert_match("%$event", m)
  h.assert_match("PullRequestReviewEvent", m)
end)

h.run_test("MUTATION_SUBMIT_REVIEW has event param", function()
  h.assert_match("%$event", graphql.MUTATION_SUBMIT_REVIEW)
  h.assert_match("PullRequestReviewEvent", graphql.MUTATION_SUBMIT_REVIEW)
end)

h.write_results("/tmp/gh_review_test_graphql.txt")
