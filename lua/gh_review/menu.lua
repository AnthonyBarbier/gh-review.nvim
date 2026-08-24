-- Native command palette for the most common review actions.

local M = {}
local picker_bufnr = -1
local picker_winid = -1

-- Store method names instead of function references so setup and tests can
-- replace top-level handlers without this module retaining stale closures.
local entries = {
  { key = "r", label = "GHReview", method = "open", argument = "" },
  { key = "p", label = "GHReviewSelect", method = "select_pr" },
  { key = "c", label = "GHReviewCommits", method = "choose_commit" },
  { key = "s", label = "GHReviewSubmit", method = "submit_review" },
  { key = "f", label = "GHReviewFiles", method = "toggle_files" },
  { key = "t", label = "GHReviewThreads", method = "choose_thread" },
}

local function close_picker()
  local winid = picker_winid
  local bufnr = picker_bufnr
  picker_winid = -1
  picker_bufnr = -1
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function run_entry(entry)
  close_picker()
  local review = require("gh_review")
  if entry.argument ~= nil then
    review[entry.method](entry.argument)
  else
    review[entry.method]()
  end
end

function M.open()
  close_picker()

  local lines = {}
  local max_width = vim.fn.strdisplaywidth("GHReview Menu · r/p/c/s/f/t")
  for _, entry in ipairs(entries) do
    local line = string.format("%s  %s", entry.key, entry.label)
    lines[#lines + 1] = line
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  picker_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_bufnr].buftype = "nofile"
  vim.bo[picker_bufnr].bufhidden = "wipe"
  vim.bo[picker_bufnr].swapfile = false
  vim.bo[picker_bufnr].filetype = "gh-review-menu"
  vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, lines)
  vim.bo[picker_bufnr].modifiable = false

  local width = math.min(max_width, math.max(1, vim.o.columns - 4))
  local height = #lines
  picker_winid = vim.api.nvim_open_win(picker_bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " GHReview Menu · r/p/c/s/f/t ",
    title_pos = "center",
  })
  vim.wo[picker_winid].cursorline = true
  vim.wo[picker_winid].wrap = false

  local function choose_current()
    local entry = entries[vim.api.nvim_win_get_cursor(picker_winid)[1]]
    if entry then run_entry(entry) end
  end
  local map_opts = { buffer = picker_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", choose_current, map_opts)
  vim.keymap.set("n", "q", close_picker, map_opts)
  vim.keymap.set("n", "<Esc>", close_picker, map_opts)
  vim.keymap.set("n", "<C-c>", close_picker, map_opts)

  -- Bind through a helper parameter so each closure owns its entry rather
  -- than depending on Lua's version-specific generic-for capture behavior.
  local function bind_entry(entry)
    vim.keymap.set("n", entry.key, function() run_entry(entry) end, map_opts)
  end
  for _, entry in ipairs(entries) do bind_entry(entry) end
end

return M
