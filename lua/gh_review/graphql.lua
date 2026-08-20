-- GraphQL queries and mutations for PR review.

local M = {}

M.QUERY_PR_DETAILS = [[
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        id
        number
        title
        state
        baseRefName
        baseRefOid
        headRefName
        headRefOid
        headRepository {
          owner { login }
          name
        }
        files(first: 100) {
          nodes {
            path
            additions
            deletions
            changeType
            viewerViewedState
          }
        }
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            line
            originalLine
            startLine
            originalStartLine
            diffSide
            path
            comments(first: 50) {
              nodes {
                id
                body
                author {
                  login
                }
                createdAt
                pullRequestReview {
                  id
                  state
                }
                reactionGroups {
                  content
                  viewerHasReacted
                  reactors(first: 0) {
                    totalCount
                  }
                }
              }
            }
          }
        }
        reviews(first: 10, states: PENDING) {
          nodes {
            id
            state
          }
        }
      }
    }
  }
]]

M.QUERY_REVIEW_THREADS = [[
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            line
            originalLine
            startLine
            originalStartLine
            diffSide
            path
            comments(first: 50) {
              nodes {
                id
                body
                author {
                  login
                }
                createdAt
                pullRequestReview {
                  id
                  state
                }
                reactionGroups {
                  content
                  viewerHasReacted
                  reactors(first: 0) {
                    totalCount
                  }
                }
              }
            }
          }
        }
      }
    }
  }
]]

-- Commits are fetched only when the commit picker is opened.  Keeping this
-- paginated query separate from QUERY_PR_DETAILS avoids slowing down the
-- normal review startup, while still allowing PRs with more than 100 commits
-- to be listed completely.
M.QUERY_PR_COMMITS = [[
  query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        commits(first: 100, after: $cursor) {
          nodes {
            commit {
              oid
              messageHeadline
              committedDate
              author {
                name
                user { login }
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
]]

-- GitHub does not expose a direct "my last review" field.  Fetch review pages
-- newest-first and let commits.lua stop at the first submitted review authored
-- by the current viewer.  Backward pagination handles PRs with many reviews.
M.QUERY_MY_LAST_REVIEW = [[
  query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    viewer { login }
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviews(last: 100, before: $cursor) {
          nodes {
            author { login }
            submittedAt
            commit { oid }
          }
          pageInfo {
            hasPreviousPage
            startCursor
          }
        }
      }
    }
  }
]]

M.QUERY_VIEWER_LOGIN = [[
  query {
    viewer { login }
  }
]]

-- The author-filtered review connection classifies whether the current viewer
-- has submitted a review without downloading every review on every open PR.
-- Pending reviews are intentionally excluded from "previously reviewed".
M.QUERY_OPEN_PULL_REQUESTS = [[
  query($owner: String!, $name: String!, $viewer: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequests(
        first: 100,
        after: $cursor,
        states: OPEN,
        orderBy: {field: UPDATED_AT, direction: DESC}
      ) {
        nodes {
          number
          title
          updatedAt
          isDraft
          author { login }
          labels(first: 100) {
            nodes { name }
          }
          reviews(
            first: 1,
            author: $viewer,
            states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]
          ) {
            totalCount
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
]]

-- Return the complete reaction summary so the thread buffer can update its
-- local comment immediately after a toggle without refetching every thread.
M.MUTATION_ADD_REACTION = [[
  mutation($subjectId: ID!, $content: ReactionContent!) {
    addReaction(input: {subjectId: $subjectId, content: $content}) {
      subject {
        id
        reactionGroups {
          content
          viewerHasReacted
          reactors(first: 0) { totalCount }
        }
      }
    }
  }
]]

M.MUTATION_REMOVE_REACTION = [[
  mutation($subjectId: ID!, $content: ReactionContent!) {
    removeReaction(input: {subjectId: $subjectId, content: $content}) {
      subject {
        id
        reactionGroups {
          content
          viewerHasReacted
          reactors(first: 0) { totalCount }
        }
      }
    }
  }
]]

M.MUTATION_START_REVIEW = [[
  mutation($pullRequestId: ID!) {
    addPullRequestReview(input: {pullRequestId: $pullRequestId}) {
      pullRequestReview {
        id
        state
      }
    }
  }
]]

M.MUTATION_CREATE_AND_SUBMIT_REVIEW = [[
  mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) {
    addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body}) {
      pullRequestReview {
        id
        state
      }
    }
  }
]]

M.MUTATION_SUBMIT_REVIEW = [[
  mutation($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String) {
    submitPullRequestReview(input: {pullRequestReviewId: $reviewId, event: $event, body: $body}) {
      pullRequestReview {
        id
        state
      }
    }
  }
]]

M.MUTATION_ADD_REVIEW_THREAD = [[
  mutation($pullRequestId: ID!, $body: String!, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide, $pullRequestReviewId: ID) {
    addPullRequestReviewThread(input: {
      pullRequestId: $pullRequestId,
      body: $body,
      path: $path,
      line: $line,
      side: $side,
      startLine: $startLine,
      startSide: $startSide,
      pullRequestReviewId: $pullRequestReviewId
    }) {
      thread {
        id
        isResolved
        line
        startLine
        diffSide
        path
        comments(first: 50) {
          nodes {
            id
            body
            author {
              login
            }
            createdAt
            pullRequestReview { id state }
          }
        }
      }
    }
  }
]]

M.MUTATION_ADD_REVIEW_COMMENT = [[
  mutation($pullRequestReviewId: ID!, $threadId: ID!, $body: String!) {
    addPullRequestReviewComment(input: {
      pullRequestReviewId: $pullRequestReviewId,
      inReplyTo: $threadId,
      body: $body
    }) {
      comment {
        id
        body
        author {
          login
        }
        createdAt
      }
    }
  }
]]

M.MUTATION_UPDATE_REVIEW_COMMENT = [[
  mutation($commentId: ID!, $body: String!) {
    updatePullRequestReviewComment(input: {
      pullRequestReviewCommentId: $commentId,
      body: $body
    }) {
      pullRequestReviewComment {
        id
        body
        author { login }
        createdAt
        pullRequestReview { id state }
      }
    }
  }
]]

M.MUTATION_DELETE_REVIEW_COMMENT = [[
  mutation($commentId: ID!) {
    deletePullRequestReviewComment(input: {id: $commentId}) {
      pullRequestReviewComment { id }
    }
  }
]]

M.MUTATION_RESOLVE_THREAD = [[
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
]]

M.MUTATION_UNRESOLVE_THREAD = [[
  mutation($threadId: ID!) {
    unresolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
]]

M.MUTATION_MARK_FILE_VIEWED = [[
  mutation($pullRequestId: ID!, $path: String!) {
    markFileAsViewed(input: {pullRequestId: $pullRequestId, path: $path}) {
      pullRequest {
        id
      }
    }
  }
]]

M.MUTATION_UNMARK_FILE_VIEWED = [[
  mutation($pullRequestId: ID!, $path: String!) {
    unmarkFileAsViewed(input: {pullRequestId: $pullRequestId, path: $path}) {
      pullRequest {
        id
      }
    }
  }
]]

M.MUTATION_DELETE_REVIEW = [[
  mutation($pullRequestReviewId: ID!) {
    deletePullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId}) {
      pullRequestReview {
        id
        state
      }
    }
  }
]]

return M
