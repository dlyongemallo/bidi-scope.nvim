-- bidi-scope.nvim - Visual hints for RTL text runs
-- Shows visual-order rendering below logical-order RTL text.

local M = {}

M.version = '0.1.0'

M.config = {
  suppress_identical = false,  -- Hide hint if visual order matches logical order.
  fix_iskeyword = true,        -- Add RTL character ranges to iskeyword (may be overridden by movement plugins).
  native_motions = true,       -- Use native word motions in buffers with RTL content (for nvim-spider compat).
}

-- Namespace for extmarks.
local ns = vim.api.nvim_create_namespace('bidi_scope_hint')

-- Cached hint state to avoid re-rendering.
local hint_cache = {
  buf = nil,
  line = nil,
  line_content = nil,
  cursor_col = nil,
  extmark_id = nil,
}

--- Reverse word order for visual display.
--- Terminal handles letter-level RTL, we just need to fix word order.
local function reverse_words(text)
  local words = {}
  for word in text:gmatch('%S+') do
    table.insert(words, 1, word)  -- Insert at front to reverse.
  end
  return table.concat(words, ' ')
end

--- Get the Unicode codepoint of a UTF-8 character.
--- TODO: Lua 5.1/LuaJIT lacks the utf8 library. Replace the following with utf8 library calls when it becomes available.
local function utf8_codepoint(char)
  local byte = char:byte(1)
  if byte < 0x80 then
    return byte
  elseif byte < 0xE0 then
    return ((byte - 0xC0) * 64) + (char:byte(2) - 0x80)
  elseif byte < 0xF0 then
    return ((byte - 0xE0) * 4096) + ((char:byte(2) - 0x80) * 64) + (char:byte(3) - 0x80)
  else
    return ((byte - 0xF0) * 262144) + ((char:byte(2) - 0x80) * 4096) +
           ((char:byte(3) - 0x80) * 64) + (char:byte(4) - 0x80)
  end
end

--- Split a UTF-8 string into characters with their byte positions.
local function utf8_chars(str)
  local chars = {}
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    local char_len = 1
    if byte >= 0xF0 then
      char_len = 4
    elseif byte >= 0xE0 then
      char_len = 3
    elseif byte >= 0xC0 then
      char_len = 2
    end
    table.insert(chars, {
      char = str:sub(i, i + char_len - 1),
      start = i,
      stop = i + char_len - 1,
    })
    i = i + char_len
  end
  return chars
end

--- Check if a codepoint is RTL (Hebrew, Arabic, etc.).
local function is_rtl(cp)
  return (cp >= 0x0590 and cp <= 0x05FF) or   -- Hebrew
         (cp >= 0x0600 and cp <= 0x06FF) or   -- Arabic
         (cp >= 0x0750 and cp <= 0x077F) or   -- Arabic Supplement
         (cp >= 0x08A0 and cp <= 0x08FF) or   -- Arabic Extended-A
         (cp >= 0xFB50 and cp <= 0xFDFF) or   -- Arabic Presentation Forms-A
         (cp >= 0xFE70 and cp <= 0xFEFF)      -- Arabic Presentation Forms-B
end

--- Check if a buffer contains any RTL characters (first 100 lines only).
local function buffer_has_rtl(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 100, false)
  for _, line in ipairs(lines) do
    local chars = utf8_chars(line)
    for _, c in ipairs(chars) do
      local cp = utf8_codepoint(c.char)
      if is_rtl(cp) then
        return true
      end
    end
  end
  return false
end

--- Check if a codepoint is weak/neutral (numbers, punctuation, space).
local function is_weak(cp)
  return (cp >= 0x0030 and cp <= 0x0039) or   -- 0-9
         (cp >= 0x0660 and cp <= 0x0669) or   -- Arabic-Indic digits
         (cp >= 0x06F0 and cp <= 0x06F9) or   -- Extended Arabic-Indic digits
         cp == 0x0020 or                       -- Space
         cp == 0x00A0 or                       -- Non-breaking space
         (cp >= 0x0021 and cp <= 0x002F) or   -- Punctuation
         (cp >= 0x003A and cp <= 0x0040) or   -- Punctuation
         (cp >= 0x005B and cp <= 0x0060) or   -- Punctuation
         (cp >= 0x007B and cp <= 0x007E)      -- Punctuation
end

--- Find all RTL runs on a line.
--- Returns: list of { start_byte, end_byte, text }, or empty list.
local function find_all_rtl_runs(line)
  local chars = utf8_chars(line)
  if #chars == 0 then
    return {}
  end

  local runs = {}
  local i = 1

  while i <= #chars do
    local cp = utf8_codepoint(chars[i].char)

    -- Look for start of RTL run.
    if is_rtl(cp) then
      local start_idx = i

      -- Expand forward to find end of run (RTL + weak chars).
      local end_idx = i
      for j = i + 1, #chars do
        local jcp = utf8_codepoint(chars[j].char)
        if is_rtl(jcp) or is_weak(jcp) then
          end_idx = j
        else
          break
        end
      end

      -- Trim trailing weak characters.
      while end_idx > start_idx do
        local ecp = utf8_codepoint(chars[end_idx].char)
        if is_weak(ecp) and not is_rtl(ecp) then
          end_idx = end_idx - 1
        else
          break
        end
      end

      local start_byte = chars[start_idx].start
      local end_byte = chars[end_idx].stop
      local text = line:sub(start_byte, end_byte)

      table.insert(runs, {
        start_byte = start_byte,
        end_byte = end_byte,
        text = text,
      })

      i = end_idx + 1
    else
      i = i + 1
    end
  end

  return runs
end

--- Clear the current hint.
local function clear_hint()
  if hint_cache.buf and hint_cache.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, hint_cache.buf, ns, hint_cache.extmark_id)
  end
  hint_cache = {
    buf = nil,
    line = nil,
    line_content = nil,
    cursor_col = nil,
    extmark_id = nil,
  }
end

--- Check if we can reuse the cached hint.
local function cache_valid(buf, line_num, line_content)
  return hint_cache.buf == buf
     and hint_cache.line == line_num
     and hint_cache.line_content == line_content
  -- Note: cursor_col is checked separately in update_hint.
end

--- Parse text into words with their byte positions.
local function parse_words(text)
  local words = {}
  local pos = 1
  for word in text:gmatch('%S+') do
    local start = text:find(word, pos, true)
    table.insert(words, {
      word = word,
      start = start,
      stop = start + #word - 1,
    })
    pos = start + #word
  end
  return words
end

--- Map cursor position from logical to visual order.
--- Returns the character offset in the visual text, or nil if cursor not in run.
local function map_cursor_to_visual(run_text, cursor_offset)
  if cursor_offset < 1 or cursor_offset > #run_text then
    return nil
  end

  local words = parse_words(run_text)
  if #words == 0 then
    return nil
  end

  -- Find which word the cursor is in.
  local cursor_word_idx = nil
  local offset_in_word = nil

  for i, w in ipairs(words) do
    if cursor_offset >= w.start and cursor_offset <= w.stop then
      cursor_word_idx = i
      offset_in_word = cursor_offset - w.start
      break
    elseif cursor_offset < w.start then
      -- Cursor is in whitespace before this word - treat as end of previous word.
      if i > 1 then
        cursor_word_idx = i - 1
        offset_in_word = #words[i - 1].word
      else
        cursor_word_idx = 1
        offset_in_word = 0
      end
      break
    end
  end

  -- If cursor is after all words, it's at the end of the last word.
  if not cursor_word_idx then
    cursor_word_idx = #words
    offset_in_word = #words[#words].word
  end

  -- Calculate position in reversed word order.
  local reversed_word_idx = #words - cursor_word_idx + 1
  local visual_pos = 0

  for i = 1, reversed_word_idx - 1 do
    local orig_idx = #words - i + 1
    visual_pos = visual_pos + #words[orig_idx].word + 1  -- +1 for space.
  end

  -- +1 because visual_pos points to end of preceding content (including space).
  return visual_pos + offset_in_word + 1
end

--- Update the hint for the current cursor position.
local function update_hint()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_num = cursor[1]
  local cursor_col = cursor[2] + 1  -- Convert to 1-indexed byte position.

  -- Get the line content.
  local lines = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)
  local line = lines[1] or ''

  -- Check if we can reuse cached hint (only if cursor hasn't moved).
  if cache_valid(buf, line_num, line) and hint_cache.cursor_col == cursor_col then
    return
  end

  -- Clear any existing hint.
  clear_hint()

  -- Find all RTL runs on the line.
  local runs = find_all_rtl_runs(line)
  if #runs == 0 then
    return
  end

  -- Build the virtual line with all runs at correct positions.
  local virt_chunks = {}
  local current_col = 0
  local any_different = false

  for _, run in ipairs(runs) do
    -- Get screen column for this run.
    local screen_col = vim.fn.virtcol({ line_num, run.start_byte })

    -- Add padding to reach this position.
    if screen_col > current_col + 1 then
      table.insert(virt_chunks, { string.rep(' ', screen_col - current_col - 1), 'Normal' })
      current_col = screen_col - 1
    end

    -- Reverse word order.
    local visual_text = reverse_words(run.text)
    if visual_text ~= run.text then
      any_different = true
    end

    -- Check if cursor is in this run.
    local cursor_in_run = cursor_col >= run.start_byte and cursor_col <= run.end_byte
    local visual_cursor_pos = nil

    if cursor_in_run then
      local cursor_offset = cursor_col - run.start_byte + 1
      visual_cursor_pos = map_cursor_to_visual(run.text, cursor_offset)
    end

    -- Add the text, highlighting cursor position if applicable.
    if visual_cursor_pos and visual_cursor_pos >= 0 then
      local chars = utf8_chars(visual_text)
      -- Find the character at visual_cursor_pos (byte offset).
      local char_idx = 1
      local byte_pos = 1
      for idx, c in ipairs(chars) do
        if byte_pos > visual_cursor_pos then
          break
        end
        char_idx = idx
        byte_pos = c.stop + 1
      end

      -- Split into before, cursor char, after.
      if char_idx <= #chars then
        local before = visual_text:sub(1, chars[char_idx].start - 1)
        local cursor_char = chars[char_idx].char
        local after = visual_text:sub(chars[char_idx].stop + 1)

        if #before > 0 then
          table.insert(virt_chunks, { before, 'Comment' })
        end
        table.insert(virt_chunks, { cursor_char, 'Cursor' })
        if #after > 0 then
          table.insert(virt_chunks, { after, 'Comment' })
        end
      else
        table.insert(virt_chunks, { visual_text, 'Comment' })
      end
    else
      table.insert(virt_chunks, { visual_text, 'Comment' })
    end

    current_col = current_col + vim.fn.strdisplaywidth(visual_text)
  end

  -- Suppress hint if all runs are identical to original.
  if M.config.suppress_identical and not any_different then
    return
  end

  -- Set extmark with virtual line.
  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line_num - 1, 0, {
    virt_lines = { virt_chunks },
    virt_lines_above = false,
  })

  -- Cache the state.
  hint_cache = {
    buf = buf,
    line = line_num,
    line_content = line,
    cursor_col = cursor_col,
    extmark_id = extmark_id,
  }
end

--- Set up native word motions for a buffer with RTL content.
local function setup_native_motions(buf)
  -- Set buffer-local iskeyword with RTL ranges.
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, 'setlocal iskeyword+=1424-1535,1536-1791')
  end)

  -- Override word motion keys with native versions (bypasses nvim-spider).
  local motions = { 'w', 'b', 'e', 'ge' }
  for _, key in ipairs(motions) do
    vim.api.nvim_buf_set_keymap(buf, 'n', key, key, {
      noremap = true,
      silent = true,
      desc = 'Native word motion (bidi-scope.nvim)',
    })
  end
end

--- Check if plugin is available (always true, no external deps).
function M.available()
  return true
end

--- Check if a hint is currently shown.
function M.active()
  return hint_cache.extmark_id ~= nil
end

--- Manually trigger hint update.
function M.hint()
  update_hint()
end

--- Clear the hint.
function M.clear()
  clear_hint()
end

function M.check()
  vim.health.start('bidi-scope.nvim')
  vim.health.ok('bidi-scope.nvim loaded (no external dependencies)')
end

function M.setup(opts)
  M.config = vim.tbl_extend('force', M.config, opts or {})

  -- Add RTL character ranges to iskeyword for proper word motions.
  if M.config.fix_iskeyword then
    pcall(vim.cmd, 'set iskeyword+=1424-1535,1536-1791')
  end

  local aug = vim.api.nvim_create_augroup('bidi_scope', { clear = true })

  -- Update hint on cursor movement.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = aug,
    callback = update_hint,
  })

  -- Clear hint when leaving buffer or on certain events.
  vim.api.nvim_create_autocmd({ 'BufLeave', 'InsertEnter' }, {
    group = aug,
    callback = clear_hint,
  })

  -- Clear hint when text changes (it may invalidate the cached run).
  vim.api.nvim_create_autocmd('TextChanged', {
    group = aug,
    callback = clear_hint,
  })

  -- Set up native word motions for buffers with RTL content.
  if M.config.native_motions then
    local checked_bufs = {}
    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufReadPost' }, {
      group = aug,
      callback = function(args)
        local buf = args.buf
        if checked_bufs[buf] then
          return
        end
        checked_bufs[buf] = true
        if buffer_has_rtl(buf) then
          setup_native_motions(buf)
        end
      end,
    })
  end

  vim.api.nvim_create_user_command('BidiScope', function(cmd)
    local subcmd = cmd.args
    if subcmd == 'on' then
      update_hint()
    elseif subcmd == 'off' then
      clear_hint()
    elseif subcmd == 'toggle' then
      if M.active() then
        clear_hint()
      else
        update_hint()
      end
    else
      vim.notify('Usage: BidiScope on|off|toggle', vim.log.levels.ERROR)
    end
  end, {
    desc = 'Control bidi hint display',
    nargs = 1,
    complete = function()
      return { 'on', 'off', 'toggle' }
    end,
  })
end

return M
