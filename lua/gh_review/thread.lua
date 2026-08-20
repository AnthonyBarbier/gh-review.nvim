-- Thread/comment buffer for viewing and replying to review threads.

local state = require("gh_review.state")
local api_mod = require("gh_review.api")
local graphql = require("gh_review.graphql")
local config = require("gh_review.config")

local M = {}
local show_thread

local function format_date(iso_date)
  -- "2024-01-15T10:30:00Z" -> "2024-01-15"
  return (iso_date:gsub("T.*", ""))
end

-- Render a configured lhs for display. <C-s> reads better as Ctrl-S, and this
-- keeps the default separator byte-identical to what syntax/gh-review-thread.vim
-- and the help file describe.
local function key_hint(lhs)
  local ctrl = lhs:match("^<[Cc]%-(.)>$")
  if ctrl then return "Ctrl-" .. ctrl:upper() end
  return lhs
end

-- The separator names the keys that act on the reply, so it has to follow
-- configuration. Disabled actions are omitted rather than shown as unusable.
-- The "── Reply below ... ──" shape is load-bearing: gh-review-thread.vim
-- matches on it.
local function reply_separator(is_editing)
  local km = config.options.keymaps.thread
  local hints = {}
  local actions = {
    { km.submit, is_editing and "save" or "submit" },
    { km.resolve, "resolve" },
    { km.close_insert, "cancel" },
  }
  if is_editing then
    actions[#actions + 1] = { km.delete_comment, "delete comment" }
  end
  for _, pair in ipairs(actions) do
    if type(pair[1]) == "string" then
      hints[#hints + 1] = string.format("%s to %s", key_hint(pair[1]), pair[2])
    end
  end
  if #hints == 0 then
    return "── Reply below ──"
  end
  return "── Reply below (" .. table.concat(hints, ", ") .. ") ──"
end

local function pending_comments(t)
  if not state.is_review_active() then return {} end
  local result = {}
  local comments = state.get(state.get(t, "comments", {}), "nodes", {})
  for _, comment in ipairs(comments) do
    local review = state.get(comment, "pullRequestReview", {})
    if state.get(review, "id", "") == state.get_pending_review_id()
        and state.get(review, "state", "") == "PENDING" then
      result[#result + 1] = comment
    end
  end
  return result
end

local function format_pending_comment(comment)
  local body = state.get(comment, "body", ""):gsub("\n.*", "")
  if #body > 60 then body = body:sub(1, 57) .. "..." end
  return string.format("%s  %s", format_date(state.get(comment, "createdAt", "")), body)
end

local function choose_pending_comment(comments, prompt, callback)
  if #comments == 0 then
    callback(nil)
  elseif #comments == 1 then
    callback(comments[1])
  else
    -- Multiple draft replies can belong to one thread.  Make the target
    -- explicit rather than guessing which saved comment the user meant.
    vim.ui.select(comments, { prompt = prompt, format_item = format_pending_comment }, callback)
  end
end

local REACTION_EMOJI = {
  THUMBS_UP = "👍",
  THUMBS_DOWN = "👎",
  LAUGH = "😄",
  HOORAY = "🎉",
  CONFUSED = "😕",
  HEART = "❤️",
  ROCKET = "🚀",
  EYES = "👀",
}

local function format_reactions(comment)
  local groups = state.get(comment, "reactionGroups", {})
  if type(groups) ~= "table" or #groups == 0 then return nil end
  local parts = {}
  for _, g in ipairs(groups) do
    local content = state.get(g, "content", "")
    local reactors = state.get(g, "reactors", {})
    local count = state.get(reactors, "totalCount", 0)
    if count > 0 then
      local emoji = REACTION_EMOJI[content] or content
      parts[#parts + 1] = emoji .. " " .. count
    end
  end
  if #parts == 0 then return nil end
  return "  " .. table.concat(parts, "  ")
end

local function get_reply_text(bufnr, reply_start)
  if reply_start < 0 then return "" end
  local lines = vim.api.nvim_buf_get_lines(bufnr, reply_start - 1, -1, false)
  -- Trim leading blank lines
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  -- Trim trailing blank lines
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function submit_new_thread(body, bufnr)
  local path = vim.b[bufnr].gh_review_path or ""
  local line_num = vim.b[bufnr].gh_review_line or 0
  local start_line = vim.b[bufnr].gh_review_start_line
  local side = vim.b[bufnr].gh_review_side or "RIGHT"

  local vars = {
    pullRequestId = state.get_pr_id(),
    body = body,
    path = path,
    line = line_num,
    side = side,
  }

  if start_line and start_line ~= vim.NIL then
    vars.startLine = start_line
    vars.startSide = side
  end

  if state.is_review_active() then
    vars.pullRequestReviewId = state.get_pending_review_id()
  end

  print("Submitting comment...")
  api_mod.graphql(graphql.MUTATION_ADD_REVIEW_THREAD, vars, function(result)
    -- GitHub returns a successful mutation payload with `thread: null` when
    -- the requested line is outside its stored PR patch.  JSON null becomes
    -- vim.NIL, which is truthy userdata in Lua, so `or {}` cannot normalize it.
    -- Use the state helper at every nullable boundary both to avoid indexing
    -- userdata and to turn this API-specific failure into an actionable error.
    local data = state.get(result, "data", {})
    local payload = state.get(data, "addPullRequestReviewThread", {})
    local new_thread = state.get(payload, "thread", {})
    if state.get(new_thread, "id", "") ~= "" then
      -- GitHub creates a pending review implicitly when the first inline thread
      -- is added without pullRequestReviewId.  Keep that server-created review
      -- in local state so a later submit updates it instead of attempting to
      -- create a second pending review, which GitHub rejects.
      local comments = state.get(state.get(new_thread, "comments", {}), "nodes", {})
      local review = state.get(comments[1] or {}, "pullRequestReview", {})
      if state.get(review, "state", "") == "PENDING" then
        local review_id = state.get(review, "id", "")
        if review_id ~= "" then state.set_pending_review_id(review_id) end
      end
      state.set_thread(new_thread.id, new_thread)
      require("gh_review.diff").refresh_signs()
      print("Comment submitted")
      M.close_thread_buffer()
    else
      vim.notify("[gh-review] line is not part of the diff", vim.log.levels.ERROR)
    end
  end)
end

local function submit_review_reply(body, bufnr)
  local first_comment_id = vim.b[bufnr].gh_review_first_comment_id or ""
  if first_comment_id == "" then
    vim.notify("[gh-review] Cannot reply: no comment ID found", vim.log.levels.ERROR)
    return
  end

  print("Submitting reply...")
  local reply_vars = {
    pullRequestReviewId = state.get_pending_review_id(),
    threadId = first_comment_id,
    body = body,
  }
  api_mod.graphql(graphql.MUTATION_ADD_REVIEW_COMMENT, reply_vars, function(result)
    local comment = ((((result or {}).data or {}).addPullRequestReviewComment or {}).comment or {})
    if comment and comment.id then
      print("Reply submitted (pending review)")
      require("gh_review").refresh_threads()
      M.close_thread_buffer()
    else
      vim.notify("[gh-review] Failed to submit reply", vim.log.levels.ERROR)
    end
  end)
end

local function update_pending_comment(body, bufnr)
  local comment_id = vim.b[bufnr].gh_review_edit_comment_id or ""
  local original_body = vim.b[bufnr].gh_review_edit_original_body or ""
  if body == original_body then
    print("Pending comment is unchanged")
    return
  end
  if body == "" then
    vim.notify("[gh-review] A comment cannot be empty; use Ctrl-D to delete it", vim.log.levels.ERROR)
    return
  end

  print("Updating pending comment...")
  local thread_id = vim.b[bufnr].gh_review_thread_id or ""
  api_mod.graphql(graphql.MUTATION_UPDATE_REVIEW_COMMENT, {
    commentId = comment_id,
    body = body,
  }, function(result)
    local updated = ((((result or {}).data or {}).updatePullRequestReviewComment or {}).pullRequestReviewComment or {})
    if not updated.id then
      vim.notify("[gh-review] Failed to update pending comment", vim.log.levels.ERROR)
      return
    end
    local t = state.get_thread(thread_id)
    local comments = state.get(state.get(t, "comments", {}), "nodes", {})
    for _, comment in ipairs(comments) do
      if comment.id == updated.id then
        -- Preserve fields omitted by the mutation (for example reactions)
        -- while installing the authoritative body returned by GitHub.
        for key, value in pairs(updated) do comment[key] = value end
        break
      end
    end
    require("gh_review.diff").refresh_signs()
    print("Pending comment updated")
    if state.get_thread_bufnr() == bufnr then M.close_thread_buffer() end
  end)
end

local function submit_reply_via_graphql(body, in_reply_to)
  local start_vars = { pullRequestId = state.get_pr_id() }
  api_mod.graphql(graphql.MUTATION_START_REVIEW, start_vars, function(result)
    local review = ((((result or {}).data or {}).addPullRequestReview or {}).pullRequestReview or {})
    if not review or not review.id then
      vim.notify("[gh-review] Failed to create review for reply", vim.log.levels.ERROR)
      return
    end
    local review_id = review.id

    local inner_vars = { pullRequestReviewId = review_id, threadId = in_reply_to, body = body }
    api_mod.graphql(graphql.MUTATION_ADD_REVIEW_COMMENT, inner_vars, function(_, comment_err)
      if comment_err then return end
      local submit_vars = { reviewId = review_id, event = "COMMENT" }
      api_mod.graphql(graphql.MUTATION_SUBMIT_REVIEW, submit_vars, function(_, submit_err)
        if submit_err then return end
        print("Reply submitted")
        require("gh_review").refresh_threads()
        M.close_thread_buffer()
      end)
    end)
  end)
end

local function submit_standalone_reply(body, bufnr)
  local first_comment_id = vim.b[bufnr].gh_review_first_comment_id or ""
  if first_comment_id == "" then
    vim.notify("[gh-review] Cannot reply: no comment ID found", vim.log.levels.ERROR)
    return
  end

  local owner = state.get_owner()
  local name = state.get_name()
  local pr_number = state.get_pr_number()

  print("Submitting reply...")
  api_mod.run_async(
    { "api", "-X", "POST",
      string.format("/repos/%s/%s/pulls/%d/comments/%s/replies", owner, name, pr_number, first_comment_id),
      "-f", "body=" .. body },
    function(stdout, stderr)
      if stderr and stderr ~= "" and not stdout:find('"id"') then
        submit_reply_via_graphql(body, first_comment_id)
        return
      end
      print("Reply submitted")
      require("gh_review").refresh_threads()
      M.close_thread_buffer()
    end)
end

local function submit_reply()
  local bufnr = state.get_thread_bufnr()
  if bufnr == -1 then return end
  local reply_start = vim.b[bufnr].gh_review_reply_start or -1
  local body = get_reply_text(bufnr, reply_start)
  local edit_comment_id = vim.b[bufnr].gh_review_edit_comment_id or ""
  if edit_comment_id ~= "" then
    update_pending_comment(body, bufnr)
    return
  end
  if body == "" then
    print("No reply text to submit")
    return
  end

  local thread_id = vim.b[bufnr].gh_review_thread_id or ""
  local is_new = vim.b[bufnr].gh_review_is_new or false

  if is_new then
    submit_new_thread(body, bufnr)
  elseif state.is_review_active() then
    submit_review_reply(body, bufnr)
  else
    submit_standalone_reply(body, bufnr)
  end
end


local function delete_pending_comment()
  local bufnr = state.get_thread_bufnr()
  if bufnr == -1 then return end
  local thread_id = vim.b[bufnr].gh_review_thread_id or ""
  local candidates = pending_comments(state.get_thread(thread_id))
  local selected_id = vim.b[bufnr].gh_review_edit_comment_id or ""
  local selected
  for _, comment in ipairs(candidates) do
    if comment.id == selected_id then selected = comment break end
  end

  local function confirm_delete(comment)
    if not comment then
      vim.notify("[gh-review] This thread has no comments in the pending review", vim.log.levels.WARN)
      return
    end
    vim.ui.select({ "Delete", "Cancel" }, {
      prompt = "Delete pending comment?",
    }, function(choice)
      if choice ~= "Delete" then return end
      api_mod.graphql(graphql.MUTATION_DELETE_REVIEW_COMMENT, {
        commentId = comment.id,
      }, function(result)
        local payload = (((result or {}).data or {}).deletePullRequestReviewComment or {})
        local deleted = payload.pullRequestReviewComment or {}
        if not deleted.id then
          vim.notify("[gh-review] Failed to delete pending comment", vim.log.levels.ERROR)
          return
        end
        print("Pending comment deleted")
        if state.get_thread_bufnr() == bufnr then M.close_thread_buffer() end
        -- Deleting the first comment can remove the entire thread, so refresh
        -- from GitHub instead of trying to repair the local thread in place.
        require("gh_review").refresh_threads()
      end)
    end)
  end

  if selected then
    confirm_delete(selected)
  else
    choose_pending_comment(candidates, "Delete pending comment:", confirm_delete)
  end
end

local function toggle_resolve()
  local bufnr = state.get_thread_bufnr()
  if bufnr == -1 then return end
  local thread_id = vim.b[bufnr].gh_review_thread_id or ""
  if thread_id == "" then
    print("Cannot resolve: thread has not been created yet")
    return
  end

  local is_resolved = vim.b[bufnr].gh_review_is_resolved or false
  local mutation = is_resolved and graphql.MUTATION_UNRESOLVE_THREAD or graphql.MUTATION_RESOLVE_THREAD
  local action = is_resolved and "Unresolving" or "Resolving"

  print(action .. " thread...")
  local resolve_vars = { threadId = thread_id }
  api_mod.graphql(mutation, resolve_vars, function(result)
    local key = is_resolved and "unresolveReviewThread" or "resolveReviewThread"
    local updated = ((((result or {}).data or {})[key] or {}).thread or {})
    if updated and updated.id then
      local t = state.get_thread(thread_id)
      t.isResolved = updated.isResolved
      state.set_thread(thread_id, t)
      require("gh_review.diff").refresh_signs()
      print(is_resolved and "Thread unresolved" or "Thread resolved")
      M.close_thread_buffer()
    else
      vim.notify("[gh-review] Failed to " .. (is_resolved and "unresolve" or "resolve") .. " thread", vim.log.levels.ERROR)
    end
  end)
end

local function enforce_read_only()
  local bufnr = vim.api.nvim_get_current_buf()
  local reply_start = vim.b[bufnr].gh_review_reply_start or 999999
  if vim.fn.line(".") < reply_start then
    vim.bo[bufnr].modifiable = false
  else
    vim.bo[bufnr].modifiable = true
  end
end

local function comment_at_cursor(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local ranges = vim.b[bufnr].gh_review_comment_ranges or {}
  local thread_id = vim.b[bufnr].gh_review_thread_id or ""
  local thread = state.get_thread(thread_id)
  local comments = state.get(state.get(thread, "comments", {}), "nodes", {})

  -- Rendered line ranges make wrapped and multi-line comment bodies behave as
  -- one reaction target. They are stored by comment ID rather than table
  -- identity because a later GitHub refresh replaces the state tables.
  for _, range in ipairs(ranges) do
    if line >= range.start_line and line <= range.end_line then
      for _, comment in ipairs(comments) do
        if state.get(comment, "id", "") == range.comment_id then
          return comment, range, thread
        end
      end
    end
  end
  return nil
end

local function toggle_reaction(content)
  return function()
    local bufnr = state.get_thread_bufnr()
    if bufnr == -1 or vim.api.nvim_get_current_buf() ~= bufnr then return end
    local comment, range, thread = comment_at_cursor(bufnr)
    if not comment then
      vim.notify("[gh-review] Place the cursor on a comment to react", vim.log.levels.WARN)
      return
    end

    local viewer_has_reacted = false
    for _, group in ipairs(state.get(comment, "reactionGroups", {})) do
      if state.get(group, "content", "") == content then
        viewer_has_reacted = state.get(group, "viewerHasReacted", false)
        break
      end
    end
    local mutation = viewer_has_reacted
        and graphql.MUTATION_REMOVE_REACTION or graphql.MUTATION_ADD_REACTION
    local payload_key = viewer_has_reacted and "removeReaction" or "addReaction"
    local cursor_offset = vim.api.nvim_win_get_cursor(0)[1] - range.start_line

    api_mod.graphql(mutation, {
      subjectId = state.get(comment, "id", ""),
      content = content,
    }, function(result, err)
      if err then return end
      local payload = state.get(state.get(result, "data", {}), payload_key, {})
      local subject = state.get(payload, "subject", {})
      if state.get(subject, "id", "") == "" then
        vim.notify("[gh-review] Failed to update reaction", vim.log.levels.ERROR)
        return
      end

      comment.reactionGroups = state.get(subject, "reactionGroups", {})
      state.set_thread(state.get(thread, "id", ""), thread)

      -- Redraw only if the same editor is still open. Preserve unsaved reply
      -- text and the cursor's position within the selected comment while the
      -- reaction count gains or loses a display line.
      if state.get_thread_bufnr() == bufnr and vim.fn.bufexists(bufnr) == 1 then
        local reply_start = vim.b[bufnr].gh_review_reply_start or -1
        local reply_body = get_reply_text(bufnr, reply_start)
        local edit_id = vim.b[bufnr].gh_review_edit_comment_id or ""
        local edit_original_body = vim.b[bufnr].gh_review_edit_original_body or ""
        local edit_comment
        for _, candidate in ipairs(state.get(state.get(thread, "comments", {}), "nodes", {})) do
          if state.get(candidate, "id", "") == edit_id then edit_comment = candidate break end
        end
        show_thread(thread, edit_comment, {
          reply_body = reply_body,
          comment_id = state.get(comment, "id", ""),
          comment_offset = cursor_offset,
          edit_original_body = edit_original_body,
        })
      end
      print(viewer_has_reacted and "Reaction removed" or "Reaction added")
    end)
  end
end

-- Action declaration for the thread buffer. `submit` and `close_insert` each
-- own two mappings with different handlers: the insert-mode variants leave
-- insert mode first. M.close_thread_buffer is referenced through a closure
-- because it is defined further down the module.
local ACTIONS = {
  submit = {
    { "n", submit_reply, "Submit reply" },
    { "i", function() vim.cmd("stopinsert") submit_reply() end, "Submit reply" },
  },
  resolve = { { "n", toggle_resolve, "Toggle resolved" } },
  delete_comment = { { "n", delete_pending_comment, "Delete pending comment" } },
  thumbs_up = { { "n", toggle_reaction("THUMBS_UP"), "Toggle thumbs-up reaction" } },
  thumbs_down = { { "n", toggle_reaction("THUMBS_DOWN"), "Toggle thumbs-down reaction" } },
  close   = { { "n", function() M.close_thread_buffer() end, "Close thread" } },
  close_insert = {
    { "n", function() M.close_thread_buffer() end, "Close thread" },
    { "i", function() vim.cmd("stopinsert") M.close_thread_buffer() end, "Close thread" },
  },
}

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.fn.getline(".")
    local col = vim.fn.col(".") - 1
    while col > 0 and line:sub(col, col) ~= "@" do
      col = col - 1
    end
    if col > 0 and line:sub(col, col) == "@" then
      return col
    end
    return -3
  end
  local participants = state.get_participants()
  local matches = {}
  for _, p in ipairs(participants) do
    if p:lower():find(base:lower(), 1, true) == 1 then
      matches[#matches + 1] = p
    end
  end
  return matches
end

show_thread = function(t, edit_comment, render_state)
  -- Close existing thread buffer if open
  M.close_thread_buffer()

  local path = state.get(t, "path", state.get_diff_path())
  local line_num = state.get(t, "line", nil)
  if not line_num or (type(line_num) == "number" and line_num <= 0) then
    line_num = state.get(t, "originalLine", 0)
  end
  local is_resolved = state.get(t, "isResolved", false)
  local thread_id = state.get(t, "id", "")
  local comments_obj = state.get(t, "comments", {})
  local comments = state.get(comments_obj, "nodes", {})
  local status_label = is_resolved and "Resolved" or "Active"
  if edit_comment then status_label = status_label .. " · Editing pending comment" end
  local is_new = (thread_id == "")

  -- Build buffer content
  local lines = {}
  local comment_ranges = {}

  if is_new then
    lines[#lines + 1] = string.format("New comment on %s:%d  [New]", path, line_num)
  else
    lines[#lines + 1] = string.format("Thread on %s:%d  [%s]", path, line_num, status_label)
  end
  lines[#lines + 1] = string.rep("─", 60)

  -- Show code context (the line(s) being commented on)
  local side = state.get(t, "diffSide", "RIGHT")
  local context_bufnr = side == "LEFT" and state.get_left_bufnr() or state.get_right_bufnr()
  if context_bufnr ~= -1 and vim.fn.bufexists(context_bufnr) == 1 then
    local start_line = state.get(t, "startLine", nil)
    if not start_line then
      start_line = state.get(t, "originalStartLine", nil)
    end
    local ctx_start = start_line or line_num
    local ctx_end = line_num
    local prefix = side == "LEFT" and "-" or "+"
    local buf_lines = vim.api.nvim_buf_get_lines(context_bufnr, ctx_start - 1, ctx_end, false)
    for i, bl in ipairs(buf_lines) do
      lines[#lines + 1] = string.format("  %d %s │ %s", ctx_start + i - 1, prefix, bl)
    end
  end

  lines[#lines + 1] = string.rep("─", 60)
  lines[#lines + 1] = ""

  -- Show existing comments
  for _, c in ipairs(comments) do
    local comment_start = #lines + 1
    local author_obj = state.get(c, "author", {})
    local author = state.get(author_obj, "login", "unknown")
    local created = format_date(state.get(c, "createdAt", ""))
    lines[#lines + 1] = string.format("%s (%s):", author, created)
    local body = state.get(c, "body", "")
    body = body:gsub("\r", "")
    local body_lines = vim.split(body, "\n", { plain = true })
    for _, bl in ipairs(body_lines) do
      lines[#lines + 1] = "  " .. bl
    end
    local reaction_line = format_reactions(c)
    if reaction_line then
      lines[#lines + 1] = reaction_line
    end
    comment_ranges[#comment_ranges + 1] = {
      comment_id = state.get(c, "id", ""),
      start_line = comment_start,
      end_line = #lines,
    }
    lines[#lines + 1] = ""
  end

  -- Reply separator
  lines[#lines + 1] = reply_separator(edit_comment ~= nil)
  lines[#lines + 1] = ""

  local reply_start = #lines

  local initial_body = state.get(t, "_initial_body", "")
  local reply_body = render_state and render_state.reply_body
  if reply_body == nil then
    reply_body = edit_comment and state.get(edit_comment, "body", "") or initial_body
  end
  if reply_body ~= "" then
    local body_lines = vim.split(reply_body, "\n", { plain = true })
    for _, bl in ipairs(body_lines) do
      lines[#lines + 1] = bl
    end
  end

  -- Create buffer in a horizontal split below the current window
  vim.cmd("botright new")
  vim.cmd("resize 15")
  local buf_name = "gh-review://thread"
  local bufnr = vim.fn.bufnr(buf_name, true)
  vim.cmd("buffer " .. bufnr)
  state.set_thread_bufnr(bufnr)
  state.set_thread_winid(vim.fn.win_getid())

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "gh-review-thread"
  local winid = vim.fn.win_getid()
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].wrap = true
  vim.wo[winid].winfixheight = true

  -- Set the buffer content
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Store metadata on the buffer
  vim.b[bufnr].gh_review_thread_id = thread_id
  vim.b[bufnr].gh_review_path = path
  vim.b[bufnr].gh_review_line = line_num
  vim.b[bufnr].gh_review_start_line = state.get(t, "startLine", vim.NIL)
  vim.b[bufnr].gh_review_side = side
  vim.b[bufnr].gh_review_reply_start = reply_start
  vim.b[bufnr].gh_review_is_new = is_new
  vim.b[bufnr].gh_review_is_resolved = is_resolved
  vim.b[bufnr].gh_review_edit_comment_id = edit_comment and edit_comment.id or ""
  vim.b[bufnr].gh_review_comment_ranges = comment_ranges
  -- Compare normalized buffer text on save so merely opening an editable
  -- pending comment never sends a redundant update mutation.
  vim.b[bufnr].gh_review_edit_original_body = render_state
      and render_state.edit_original_body
      or (edit_comment and state.get(edit_comment, "body", "") or "")

  -- Store the first comment id (needed for REST reply)
  if #comments > 0 then
    vim.b[bufnr].gh_review_first_comment_id = comments[1].id
  end

  -- Make the header area read-only via autocmd
  local augroup = vim.api.nvim_create_augroup("gh_review_thread", { clear = false })
  vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = bufnr,
    callback = submit_reply,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = enforce_read_only,
  })

  -- Keymaps
  config.apply_keymaps(bufnr, "thread", ACTIONS)

  -- Set omnifunc for @-mention completion
  vim.bo[bufnr].omnifunc = "v:lua.require'gh_review.thread'.omnifunc"

  -- Position cursor at the reply area
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if render_state and render_state.comment_id then
    for _, range in ipairs(comment_ranges) do
      if range.comment_id == render_state.comment_id then
        local target = range.start_line + (render_state.comment_offset or 0)
        target = math.max(range.start_line, math.min(target, range.end_line))
        vim.api.nvim_win_set_cursor(0, { target, 0 })
        -- The reaction redraw deliberately lands back in the read-only header;
        -- apply that state synchronously instead of waiting for CursorMoved.
        vim.bo[bufnr].modifiable = false
        return
      end
    end
  end
  if reply_body ~= "" then
    local target = math.min(reply_start + 2, total_lines)
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  else
    vim.api.nvim_win_set_cursor(0, { math.min(reply_start, total_lines), 0 })
    if is_new then
      vim.cmd("startinsert")
    end
  end
end

-- Open an existing thread by id.
function M.open(thread_id)
  local t = state.get_thread(thread_id)
  if not t or not next(t) then
    vim.notify("[gh-review] Thread not found: " .. thread_id, vim.log.levels.ERROR)
    return
  end
  choose_pending_comment(pending_comments(t), "Edit pending comment:", function(comment)
    show_thread(t, comment)
  end)
end

-- Open a new comment thread (no existing comments yet).
function M.open_new(path, start_line, end_line, side, initial_body)
  initial_body = initial_body or ""
  local pseudo_thread = {
    id = "",
    path = path,
    line = end_line,
    startLine = start_line ~= end_line and start_line or vim.NIL,
    diffSide = side,
    isResolved = false,
    comments = { nodes = {} },
    _initial_body = initial_body,
  }
  show_thread(pseudo_thread)
end

function M.close_thread_buffer()
  local bufnr = state.get_thread_bufnr()
  if bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1 then
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      vim.bo[bufnr].modified = false
      vim.cmd("close")
    end
    if vim.fn.bufexists(bufnr) == 1 then
      vim.cmd("silent! bwipeout! " .. bufnr)
    end
  end
  state.set_thread_bufnr(-1)
  state.set_thread_winid(-1)

  -- Let diff windows expand into the freed space and redraw.
  vim.cmd("wincmd =")
  local left_winid = vim.fn.bufwinid(state.get_left_bufnr())
  if left_winid ~= -1 then
    vim.fn.win_gotoid(left_winid)
    vim.cmd([[execute "normal! \<C-e>\<C-y>"]])
  end
  local right_winid = vim.fn.bufwinid(state.get_right_bufnr())
  if right_winid ~= -1 then
    vim.fn.win_gotoid(right_winid)
    vim.cmd([[execute "normal! \<C-e>\<C-y>"]])
  end
end

return M
