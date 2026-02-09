-- bidi-scope.nvim - Visual hints for RTL text runs
-- Shows visual-order rendering below logical-order RTL text.

local M = {}

M.version = '0.1.0'

M.config = {
  suppress_identical = false,  -- Hide hint if visual order matches logical order.
  fix_iskeyword = true,        -- Add RTL character ranges to iskeyword (may be overridden by movement plugins).
  native_motions = true,       -- Use native word motions in buffers with RTL content (for nvim-spider compat).
  replace_zwnj = false,        -- Replace ZWNJ with dotted circle.
  swap_zwnj_parts = false,     -- Swap parts of a word around a ZWNJ (at most one per word).
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

-- ZWNJ character (U+200C) in UTF-8.
local ZWNJ = vim.fn.nr2char(0x200C)
-- Dotted circle (U+25CC) - visible marker for ZWNJ position.
local DOTTED_CIRCLE = vim.fn.nr2char(0x25CC)

--- Swap parts of a word around a ZWNJ.
--- Only handles at most one ZWNJ per word.
local function swap_zwnj_word(word)
  local pos = word:find(ZWNJ, 1, true)
  if not pos then
    return word
  end
  local before = word:sub(1, pos - 1)
  local after = word:sub(pos + #ZWNJ)
  return after .. ZWNJ .. before
end

--- Reverse word order for visual display, preserving original whitespace.
local function reverse_words(text)
  local words = {}
  local gaps = {}
  local pos = 1
  local len = #text
  while pos <= len do
    -- Match whitespace gap.
    local gap_start = pos
    while pos <= len and text:sub(pos, pos):match('%s') do
      pos = pos + 1
    end
    if pos > gap_start then
      table.insert(gaps, text:sub(gap_start, pos - 1))
    end
    -- Match word.
    local word_start = pos
    while pos <= len and not text:sub(pos, pos):match('%s') do
      pos = pos + 1
    end
    if pos > word_start then
      table.insert(words, text:sub(word_start, pos - 1))
    end
  end
  -- Reverse both words and gaps.
  local parts = {}
  for i = #words, 1, -1 do
    parts[#parts + 1] = words[i]
    if i > 1 then
      local gap_idx = #gaps - (#words - i)
      parts[#parts + 1] = (gap_idx >= 1 and gaps[gap_idx]) or ' '
    end
  end
  return table.concat(parts)
end

--- Convert text to visual order for hint display.
--- Applies ZWNJ workarounds (swap/replace) before reversing word order.
local function to_visual_order(text)
  local result = text
  if M.config.swap_zwnj_parts then
    result = result:gsub('%S+', function(word)
      return swap_zwnj_word(word)
    end)
  end
  if M.config.replace_zwnj then
    result = result:gsub(ZWNJ, DOTTED_CIRCLE)
  end
  return reverse_words(result)
end

--- Get the Unicode codepoint of a UTF-8 character.
--- Returns nil for invalid or empty input.
--- TODO: Lua 5.1/LuaJIT lacks the utf8 library. Replace with utf8.codepoint() when available.
local function utf8_codepoint(char)
  if not char or #char == 0 then
    return nil
  end
  local byte = char:byte(1)
  if byte < 0x80 then
    return byte
  elseif byte < 0xE0 then
    local b2 = char:byte(2)
    if not b2 then return nil end
    return ((byte - 0xC0) * 64) + (b2 - 0x80)
  elseif byte < 0xF0 then
    local b2, b3 = char:byte(2), char:byte(3)
    if not b2 or not b3 then return nil end
    return ((byte - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
  elseif byte < 0xF8 then
    local b2, b3, b4 = char:byte(2), char:byte(3), char:byte(4)
    if not b2 or not b3 or not b4 then return nil end
    return ((byte - 0xF0) * 262144) + ((b2 - 0x80) * 4096) +
           ((b3 - 0x80) * 64) + (b4 - 0x80)
  end
  return nil  -- Invalid leading byte (0xF8-0xFF).
end

--- Split a UTF-8 string into characters with their byte positions.
--- Handles invalid sequences by treating each invalid byte as a single character.
local function utf8_chars(str)
  local chars = {}
  local i = 1
  local len = #str
  while i <= len do
    local byte = str:byte(i)
    local char_len = 1
    if byte >= 0xF0 and byte < 0xF8 then
      char_len = 4
    elseif byte >= 0xE0 then
      char_len = 3
    elseif byte >= 0xC2 then  -- 0xC0-0xC1 are invalid (overlong encodings).
      char_len = 2
    elseif byte >= 0x80 then
      -- Continuation byte or invalid; treat as single byte.
      char_len = 1
    end
    -- Clamp to string length.
    if i + char_len - 1 > len then
      char_len = len - i + 1
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

--- Check if a codepoint is RTL (Bidi_Class R or AL).
--- Based on Unicode DerivedBidiClass.txt.
local function is_rtl(cp)
  if not cp then return false end
  -- Basic Multilingual Plane (BMP) RTL scripts.
  if (cp >= 0x0590 and cp <= 0x05FF) or   -- Hebrew
     (cp >= 0x0600 and cp <= 0x06FF) or   -- Arabic
     (cp >= 0x0700 and cp <= 0x074F) or   -- Syriac
     (cp >= 0x0750 and cp <= 0x077F) or   -- Arabic Supplement
     (cp >= 0x0780 and cp <= 0x07BF) or   -- Thaana
     (cp >= 0x07C0 and cp <= 0x07FF) or   -- N'Ko
     (cp >= 0x0800 and cp <= 0x083F) or   -- Samaritan
     (cp >= 0x0840 and cp <= 0x085F) or   -- Mandaic
     (cp >= 0x0860 and cp <= 0x086F) or   -- Syriac Supplement
     (cp >= 0x0870 and cp <= 0x089F) or   -- Arabic Extended-B
     (cp >= 0x08A0 and cp <= 0x08FF) or   -- Arabic Extended-A
     cp == 0x200F or                       -- Right-to-Left Mark
     (cp >= 0xFB1D and cp <= 0xFB4F) or   -- Hebrew Presentation Forms
     (cp >= 0xFB50 and cp <= 0xFDFF) or   -- Arabic Presentation Forms-A
     (cp >= 0xFE70 and cp <= 0xFEFF) then  -- Arabic Presentation Forms-B
    return true
  end
  -- Supplementary Multilingual Plane (SMP) RTL scripts.
  if cp >= 0x10000 then
    return (cp >= 0x10800 and cp <= 0x10CFF) or  -- Cypriot through Old Hungarian
           (cp >= 0x10D00 and cp <= 0x10D3F) or  -- Hanifi Rohingya
           (cp >= 0x10E60 and cp <= 0x10EBF) or  -- Rumi, Yezidi
           (cp >= 0x10EC0 and cp <= 0x10EFF) or  -- Arabic Extended-C
           (cp >= 0x10F00 and cp <= 0x10FFF) or  -- Old Sogdian through Elymaic
           (cp >= 0x1E800 and cp <= 0x1E8DF) or  -- Mende Kikakui
           (cp >= 0x1E900 and cp <= 0x1E95F) or  -- Adlam
           (cp >= 0x1EC70 and cp <= 0x1ECBF) or  -- Indic Siyaq Numbers
           (cp >= 0x1ED00 and cp <= 0x1ED4F) or  -- Ottoman Siyaq Numbers
           (cp >= 0x1EE00 and cp <= 0x1EEFF)     -- Arabic Mathematical Symbols
  end
  return false
end

--- Check if a buffer contains any RTL characters (first 100 lines only).
--- Uses a direct byte scan to avoid table allocations.
local function buffer_has_rtl(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 100, false)
  for _, line in ipairs(lines) do
    local len = #line
    local i = 1
    while i <= len do
      local b = line:byte(i)
      if b < 0x80 then
        -- ASCII: skip.
        i = i + 1
      elseif b >= 0xC2 and b <= 0xDF then
        -- 2-byte sequence. RTL starts at U+0590 (0xD6 0x90).
        if b >= 0xD6 then
          local b2 = line:byte(i + 1)
          if b2 then
            local cp = (b - 0xC0) * 64 + (b2 - 0x80)
            if is_rtl(cp) then return true end
          end
        end
        i = i + 2
      elseif b >= 0xE0 and b <= 0xEF then
        -- 3-byte sequence. Only certain leading bytes can encode BMP RTL codepoints.
        if b == 0xE0 or b == 0xE2 or b == 0xEF then
          local b2, b3 = line:byte(i + 1), line:byte(i + 2)
          if b2 and b3 then
            local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            if is_rtl(cp) then return true end
          end
        end
        i = i + 3
      elseif b >= 0xF0 and b <= 0xF7 then
        -- 4-byte sequence (SMP, rare in practice).
        local b2, b3, b4 = line:byte(i + 1), line:byte(i + 2), line:byte(i + 3)
        if b2 and b3 and b4 then
          local cp = (b - 0xF0) * 262144 + (b2 - 0x80) * 4096
                   + (b3 - 0x80) * 64 + (b4 - 0x80)
          if is_rtl(cp) then return true end
        end
        i = i + 4
      else
        -- Continuation or invalid byte: skip.
        i = i + 1
      end
    end
  end
  return false
end

--- Check if a codepoint is weak/neutral (numbers, punctuation, space, formatting).
--- These characters should not break RTL runs.
local function is_weak(cp)
  if not cp then return false end
  -- ASCII.
  if cp == 0x0009 or                       -- Tab
     cp == 0x0020 or                       -- Space
     (cp >= 0x0021 and cp <= 0x002F) or   -- !"#$%&'()*+,-./
     (cp >= 0x0030 and cp <= 0x0039) or   -- 0-9
     (cp >= 0x003A and cp <= 0x0040) or   -- :;<=>?@
     (cp >= 0x005B and cp <= 0x0060) or   -- [\]^_`
     (cp >= 0x007B and cp <= 0x007E) then  -- {|}~
    return true
  end
  -- Latin-1 Supplement punctuation and symbols.
  if cp == 0x00A0 or                       -- Non-breaking space
     (cp >= 0x00A1 and cp <= 0x00BF) then  -- Inverted punctuation, currency, etc.
    return true
  end
  -- Hebrew punctuation (not letters).
  if cp == 0x05BE or                       -- Maqaf (hyphen)
     cp == 0x05C0 or                       -- Paseq
     cp == 0x05C3 or                       -- Sof Pasuq
     cp == 0x05C6 or                       -- Nun Hafukha
     cp == 0x05F3 or                       -- Geresh
     cp == 0x05F4 then                     -- Gershayim
    return true
  end
  -- Arabic punctuation and numbers.
  if cp == 0x060C or                       -- Arabic Comma
     cp == 0x061B or                       -- Arabic Semicolon
     cp == 0x061F or                       -- Arabic Question Mark
     cp == 0x0640 or                       -- Tatweel
     (cp >= 0x0660 and cp <= 0x0669) or   -- Arabic-Indic digits
     (cp >= 0x06F0 and cp <= 0x06F9) then  -- Extended Arabic-Indic digits
    return true
  end
  -- General Punctuation block.
  if (cp >= 0x2000 and cp <= 0x200A) or   -- Various spaces
     (cp >= 0x200B and cp <= 0x200F) or   -- Zero-width chars, LRM, RLM
     (cp >= 0x2010 and cp <= 0x2027) or   -- Dashes, quotes, bullets
     cp == 0x202F or                       -- Narrow no-break space
     cp == 0x2039 or                       -- Single left angle quote
     cp == 0x203A or                       -- Single right angle quote
     cp == 0x2060 or                       -- Word Joiner
     (cp >= 0x2066 and cp <= 0x2069) then  -- Bidi isolates
    return true
  end
  -- Bidi control characters.
  if cp >= 0x202A and cp <= 0x202E then   -- LRE, RLE, PDF, LRO, RLO
    return true
  end
  -- Currency symbols.
  if cp >= 0x20A0 and cp <= 0x20CF then
    return true
  end
  -- Misc.
  if cp == 0xFEFF then                     -- BOM / ZWNBSP
    return true
  end
  return false
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

--- Build a byte position mapping from original to visual order.
--- Returns a table mapping original byte positions to visual byte positions.
local function build_position_map(text)
  -- Parse into characters with positions.
  local chars = utf8_chars(text)
  if #chars == 0 then
    return {}
  end

  -- Group characters into words and inter-word gap segments.
  local word_list = {}
  local gap_list = {}
  local current_word = { chars = {} }
  local current_gap = {}

  for i, c in ipairs(chars) do
    if c.char:match('^%s$') then
      if #current_word.chars > 0 then
        table.insert(word_list, current_word)
        current_word = { chars = {} }
      end
      table.insert(current_gap, { char = c.char, orig_idx = i })
    else
      if #current_gap > 0 then
        table.insert(gap_list, current_gap)
        current_gap = {}
      end
      table.insert(current_word.chars, { char = c.char, orig_idx = i })
    end
  end
  if #current_word.chars > 0 then
    table.insert(word_list, current_word)
  end

  -- Reverse word order and gap order.
  local reversed_words = {}
  for i = #word_list, 1, -1 do
    table.insert(reversed_words, word_list[i])
  end
  local reversed_gaps = {}
  for i = #gap_list, 1, -1 do
    table.insert(reversed_gaps, gap_list[i])
  end

  -- Build mapping from original char index to visual byte position.
  -- Within each word (or each half of a ZWNJ-split word), mirror the position
  -- so the highlight moves in the opposite direction from the cursor.
  local orig_to_visual = {}
  local visual_byte = 1

  for i, w in ipairs(reversed_words) do
    local word_chars = w.chars

    -- Check for ZWNJ swap: find the ZWNJ boundary within this word.
    local zwnj_idx = nil
    if M.config.swap_zwnj_parts then
      for k, c in ipairs(word_chars) do
        if c.char == ZWNJ then
          zwnj_idx = k
          break
        end
      end
    end

    if zwnj_idx then
      -- ZWNJ swap active: lay out bytes as [after, ZWNJ, before] and
      -- mirror within each half independently.
      local before = {}
      for k = 1, zwnj_idx - 1 do
        table.insert(before, word_chars[k])
      end
      local zwnj_char = word_chars[zwnj_idx]
      local after = {}
      for k = zwnj_idx + 1, #word_chars do
        table.insert(after, word_chars[k])
      end

      -- Compute byte positions in swapped layout: [after][ZWNJ][before].
      local pos = visual_byte
      local after_positions = {}
      for _, c in ipairs(after) do
        table.insert(after_positions, pos)
        pos = pos + #c.char
      end
      local zwnj_pos = pos
      pos = pos + #zwnj_char.char
      local before_positions = {}
      for _, c in ipairs(before) do
        table.insert(before_positions, pos)
        pos = pos + #c.char
      end

      -- Mirror within the after part.
      for j, c in ipairs(after) do
        orig_to_visual[c.orig_idx] = after_positions[#after - j + 1]
      end
      -- ZWNJ maps to its own position.
      orig_to_visual[zwnj_char.orig_idx] = zwnj_pos
      -- Mirror within the before part.
      for j, c in ipairs(before) do
        orig_to_visual[c.orig_idx] = before_positions[#before - j + 1]
      end

      visual_byte = pos
    else
      -- No ZWNJ split: full-word mirror.
      local word_len = #word_chars
      local char_positions = {}
      local pos = visual_byte
      for _, c in ipairs(word_chars) do
        table.insert(char_positions, pos)
        pos = pos + #c.char
      end
      for j, c in ipairs(word_chars) do
        orig_to_visual[c.orig_idx] = char_positions[word_len - j + 1]
      end
      visual_byte = pos
    end

    -- Map inter-word gap.
    if i < #reversed_words and reversed_gaps[i] then
      for _, gc in ipairs(reversed_gaps[i]) do
        orig_to_visual[gc.orig_idx] = visual_byte
        visual_byte = visual_byte + #gc.char
      end
    end
  end

  -- Build mapping from original byte position to visual byte position.
  local byte_map = {}
  for i, c in ipairs(chars) do
    local visual_pos = orig_to_visual[i]
    if visual_pos then
      -- Map each byte of this character.
      for b = 0, #c.char - 1 do
        byte_map[c.start + b] = visual_pos + b
      end
    end
  end

  return byte_map
end

--- Map cursor position from logical to visual order.
--- Returns the byte offset in the visual text, or nil if not mappable.
local function map_cursor_to_visual(text, cursor_offset)
  if cursor_offset < 1 or cursor_offset > #text then
    return nil
  end

  local byte_map = build_position_map(text)
  return byte_map[cursor_offset]
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

    -- Convert to visual order (includes ZWNJ workarounds).
    local visual_text = to_visual_order(run.text)
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

--- Check if plugin is available (always true).
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
  vim.health.ok('bidi-scope.nvim loaded')

  -- Check iskeyword ranges.
  local iskw = vim.o.iskeyword
  local has_hebrew = iskw:find('1424%-1535') ~= nil
  local has_arabic = iskw:find('1536%-1791') ~= nil
  if M.config.fix_iskeyword then
    if has_hebrew and has_arabic then
      vim.health.ok('iskeyword contains RTL ranges (1424-1535, 1536-1791)')
    else
      vim.health.warn('iskeyword missing RTL ranges; fix_iskeyword is enabled but ranges not yet applied')
    end
  else
    vim.health.info('fix_iskeyword is disabled by config')
  end

  -- Check native_motions keymaps.
  if M.config.native_motions then
    local buf = vim.api.nvim_get_current_buf()
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    local found = false
    for _, map in ipairs(maps) do
      if map.desc and map.desc:find('bidi%-scope') then
        found = true
        break
      end
    end
    if found then
      vim.health.ok('native_motions keymaps found in current buffer')
    else
      vim.health.info('native_motions keymaps not found in current buffer (expected if no RTL content)')
    end
  else
    vim.health.info('native_motions is disabled by config')
  end
end

function M.setup(opts)
  M.config = vim.tbl_extend('force', M.config, opts or {})

  -- Add RTL character ranges to iskeyword for proper word motions.
  if M.config.fix_iskeyword then
    pcall(vim.cmd, 'set iskeyword+=1424-1535,1536-1791')
  end

  local aug = vim.api.nvim_create_augroup('bidi_scope', { clear = true })

  -- Update hint on cursor movement and text changes.
  vim.api.nvim_create_autocmd({
    'CursorMoved',
    'CursorMovedI',
    'TextChanged',
    'TextChangedI',
    'InsertLeave',
  }, {
    group = aug,
    callback = update_hint,
  })

  -- Clear hint when leaving buffer.
  vim.api.nvim_create_autocmd('BufLeave', {
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
