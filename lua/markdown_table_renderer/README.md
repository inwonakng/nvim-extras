# Markdown table renderer

A local Neovim renderer for GFM pipe tables. It keeps the Markdown buffer as the source of truth, fits columns to the active window, wraps cell content, hides table source lines with `conceal_lines`, and displays the result with `virt_lines`.

Tables are rendered automatically while the cursor is outside them. Moving the cursor into a table reveals its source for normal editing; moving away renders it again. The renderer never changes `wrap` or rewrites source text.

## Requirements

- Neovim 0.11 or newer (`conceal_lines`)
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

Virtual decorations belong to a buffer, so when the same buffer appears in windows with different widths the renderer uses the active window's width. Entering a table in the active window reveals that table in every window showing the buffer.
