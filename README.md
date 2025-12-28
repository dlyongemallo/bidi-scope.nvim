# bidi-scope.nvim

Display visual hints for RTL text runs inside LTR text.

> **Note**: If you need full bidirectional text editing, you probably want a
> terminal that supports [termbidi](https://neovim.io/doc/user/options.html#'termbidi').
> This plugin is for the limited use case of editing files with mostly LTR text
> but occasional RTL runs in a terminal without termbidi support.
> It does not change underlying logical text or cursor movement behaviour.

## What it does

Shows correct visual word order below RTL text runs. Terminals typically handle
letter-level RTL (shaping and joining) but display words in logical order. This
plugin adds a hint line showing the correct reading order.

```
Buffer:    Hello سلام دنیا World
Hint:            دنیا سلام        (correct visual word order)
```

When the cursor is inside an RTL run, its position is highlighted in the hint line.

## Requirements

- Neovim 0.9+

## Install

```lua
-- lazy.nvim
{ 'dlyongemallo/bidi-scope.nvim', config = true }
```

## Usage

After setup, hints appear automatically when the cursor is on a line containing
RTL text (Hebrew, Arabic, Persian, Urdu, etc.).

Commands:
- `:BidiScope on` — show hint for current line
- `:BidiScope off` — clear the hint
- `:BidiScope toggle` — toggle hint visibility

```lua
local bidi_scope = require('bidi-scope')
bidi_scope.hint()      -- Manually trigger hint update
bidi_scope.clear()     -- Clear the hint
bidi_scope.active()    -- Check if a hint is shown
```

## Config

```lua
require('bidi-scope').setup({
  suppress_identical = false, -- Hide hint if visual = logical (default: false)
  fix_iskeyword = true,       -- Add RTL ranges to iskeyword (default: true)
  native_motions = true,      -- Use native motions in RTL buffers (default: true)
})
```

### Options

**suppress_identical**: When `true`, hides the hint line if reversing word
order produces identical text (e.g., single-word RTL runs).

**fix_iskeyword**: When `true`, adds Hebrew and Arabic character ranges to
`iskeyword` so word motions (`w`, `b`, `e`) work properly in RTL text.
Note: This may be overridden by movement plugins such as [`nvim-spider`](https://github.com/chrisgrieser/nvim-spider),
in which case see the next option.

**native_motions**: When `true`, buffers containing RTL text automatically get
buffer-local word motion mappings (`w`, `b`, `e`, `ge`) that use native Vim
motions with proper `iskeyword` settings for RTL characters.

## Compatibility

Movement plugins like `nvim-spider` implement their own word motion logic
which might not support Unicode. The `native_motions` option (enabled by
default) provides buffer-local mappings that override these plugins in buffers
containing RTL text, restoring native Vim word motions with proper `iskeyword`
settings.

## Health

```vim
:checkhealth bidi-scope
```

## How it works

1. Detects RTL character runs using Unicode ranges.
2. Finds all RTL runs on the current line.
3. Reverses word order within each run for visual display.
4. Shows hints as virtual lines below the text using extmarks.
5. Maps cursor position from logical to visual order.

## License

MIT
