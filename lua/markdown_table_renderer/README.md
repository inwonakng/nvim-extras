# Markdown table renderer

A local Neovim renderer for GFM pipe tables. It keeps the Markdown buffer as the source of truth, fits columns to the active window, and wraps cell content. Each source row remains a real buffer line: its text is concealed and replaced with virtual text, with wrapped continuations and borders displayed as virtual lines.

In Normal mode, only the cursor's row reveals its Markdown source; the rest of the table stays rendered. Ordinary `j`/`k` motions reach every source row, including the header and delimiter. Insert and Replace modes reveal the whole table containing the cursor. Characterwise, linewise, and blockwise Visual selections reveal every table they intersect, even when the selection endpoints are outside the table. Leaving those modes restores row-based rendering. The renderer never changes `wrap` or rewrites source text.

Native end-of-line diagnostic text appears after the rendered row's right border, rather than over its cells. Wrapped continuations remain below that first display line. Revealed source rows use Neovim's ordinary diagnostic placement.

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

When `latex_renderer` is also enabled, converted inline math is laid out inside table cells before column sizing and wrapping. Multiline formulas retain their baselines and stay together when wrapping. Revealed rows show the original math source, with no separate math decorations. Pending or failed conversions remain readable as source text. Setup order does not matter; enabling tables alone does not load the math renderer or require `utftex`.

## Commands

- `:MarkdownTableRendererRefresh` clears cached inline parsing and redraws tables.

## Limitations

- Display-style math such as `$$…$$` inside cells remains source text; table cells do not place Kitty images. Use `$…$` for converted inline math. An indivisible formula can make its column wider than the configured width limit.
- Wrapped virtual continuation lines are not cursor-addressable; `j`/`k` traverse source rows, not every displayed line.
- Revealing a row can change its displayed height because its original Markdown replaces the rendered wrapping. Borders attached to that row also disappear while it is revealed.
- Virtual decorations belong to a buffer, so when the same buffer appears in windows with different widths the renderer uses the active window's width. Rows or tables revealed in the active window are revealed in every window showing the buffer.

## Development checks

With the Tree-sitter parsers installed on Neovim's runtimepath, run from the checkout:

```sh
nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/markdown_table_renderer.lua')"
```

The tests exercise screen output, diagnostic placement on rendered and revealed rows, source-row navigation, mode transitions, selections spanning tables, resizing, edits and undo, and tables at buffer boundaries.

For math integration, also install the `latex` parser and run both setup orders (conversion is stubbed, so no external math executables are needed):

```sh
nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/markdown_table_math.lua')"
NVIM_EXTRAS_TABLE_FIRST=1 nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/markdown_table_math.lua')"
```
