# Markdown table renderer

A local Neovim renderer for GFM pipe tables. It keeps the Markdown buffer as the source of truth, fits columns to the active window, and wraps cell content. Each source row remains a real buffer line: its text is concealed and replaced with virtual text, with wrapped continuations and borders displayed as virtual lines.

In Normal mode, only the cursor's row reveals its Markdown source; the rest of the table stays rendered. Ordinary `j`/`k` motions reach every source row, including the header and delimiter. Insert and Replace modes reveal the whole table containing the cursor. Characterwise, linewise, and blockwise Visual selections reveal every table they intersect, even when the selection endpoints are outside the table. Leaving those modes restores row-based rendering. The renderer never changes `wrap` or rewrites source text.

## Requirements

- Neovim 0.11 or newer
- Tree-sitter `markdown` and `markdown_inline` parsers

## Setup

```lua
require("markdown_table_renderer").setup({
	max_width_ratio = 0.95,
	min_col_width = 6,
	max_col_width = 40,
})
```

Another Markdown renderer may handle the rest of the document, but its pipe-table renderer must be disabled.

## Commands

- `:MarkdownTableRendererRefresh` clears cached inline parsing and redraws tables.

## Limitations

- Wrapped virtual continuation lines are not cursor-addressable; `j`/`k` traverse source rows, not every displayed line.
- Revealing a row can change its displayed height because its original Markdown replaces the rendered wrapping. Borders attached to that row also disappear while it is revealed.
- Virtual decorations belong to a buffer, so when the same buffer appears in windows with different widths the renderer uses the active window's width. Rows or tables revealed in the active window are revealed in every window showing the buffer.

## Development checks

With the Tree-sitter parsers installed on Neovim's runtimepath, run from the checkout:

```sh
nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/markdown_table_renderer.lua')"
```

The tests exercise screen output, source-row navigation, mode transitions, selections spanning tables, resizing, edits and undo, and tables at buffer boundaries.
