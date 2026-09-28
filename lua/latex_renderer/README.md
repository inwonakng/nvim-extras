# LaTeX Renderer

A shared Neovim module used by `litenvim` and `pi-console` to render Markdown math.

## Rendering

The module owns two rendering paths:

- **Display math:** equations are compiled to transparent PNGs and placed with the Kitty graphics protocol.
- **Inline math:** equations are converted to Unicode with `utftex` and displayed with extmarks.

Display blocks may use delimiter-only lines, with optional indentation:

```markdown
$$
x = y
$$
```

```markdown
\[
x = y
\]
```

The display-fence scanner owns these newline-delimited forms so Markdown constructs such as Setext heading underlines and list markers inside an equation do not split it. Tree-sitter continues to detect inline math and other LaTeX forms. Dedicated display ranges take precedence over overlapping Tree-sitter captures.

Using `utftex` supports constructs such as `\mathcal`, `\mathbb`, fractions, roots, and scripts without maintaining a partial LaTeX parser here. Math delimiters inside fenced or indented code blocks and multiline code spans are ignored. LaTeX injected for fenced `tex` or `latex` code blocks remains syntax-highlighted source.

## Dependencies

### Neovim

- A recent Neovim with `vim.system`, `vim.fs`, Tree-sitter, extmarks, and `vim.api.nvim_ui_send` (tested with Neovim 0.12).
- `nvim-treesitter` with the `markdown`, `markdown_inline`, and `latex` parsers.

### Executables

- `pdflatex`, provided by TeX Live or MacTeX.
- ImageMagick's `magick` executable.
- `utftex` for inline LaTeX-to-Unicode conversion.

The TeX installation must provide `standalone`, `xcolor`, `amsmath`, `amssymb`, `amsfonts`, `amscd`, and `mathtools`.

On macOS, ImageMagick and utftex can be installed with:

```sh
brew install imagemagick utftex
```

Install MacTeX or another TeX Live distribution separately to provide `pdflatex` and the required packages.

### Terminal

- A terminal implementing the Kitty graphics protocol, such as Kitty or Ghostty.
- When running inside tmux, `allow-passthrough` must be enabled.

The nested-client hooks in pi-console's tmux integration set `@graphics-nest-count`. The renderer reads that value so graphics sent from a nested popup receive the correct number of tmux passthrough wrappers.

## Configuration

Display rendering is configured with:

```lua
require("latex_renderer").setup({
    scale = 0.8,
})
```

Available options and their defaults are:

```lua
{
    debounce_ms = 30,
    max_width = 80,
    max_height = 30,
    prefetch_lines = 30,
    scale = 0.8,
}
```

`scale` controls the displayed image dimensions. `max_width` and `max_height` cap those dimensions in terminal cells.

When using `render-markdown.nvim` alongside this module, disable its LaTeX handler so this module remains the sole owner of math rendering:

```lua
latex = {
    enabled = false,
}
```

## Behavior

- Inline and non-fenced display equations are found through LaTeX trees injected by `markdown_inline`.
- Newline-delimited `$$` and `\[` display blocks are found by the dedicated display-fence scanner.
- LaTeX trees injected directly from fenced code blocks are ignored.
- Only equations in or near a visible viewport are converted or compiled.
- Raw inline source is shown for every equation on the cursor line.
- Successful inline conversions and their `utftex` baselines are cached in memory by source.
- PNGs are cached under `stdpath("cache")/latex-renderer` using the source and foreground color.
- At most two LaTeX compilation jobs run concurrently.
- `:LatexRendererRefresh` retries failed equations and retransmits cached images.

## Files

- `init.lua`: Tree-sitter integration, scheduling, and buffer lifecycle.
- `display_fences.lua`: newline-delimited display-math scanning.
- `inline.lua`: inline extmark and multiline Unicode layout.
- `utftex.lua`: asynchronous inline conversion and result caching.
- `compiler.lua`: asynchronous LaTeX compilation and PNG caching.
- `kitty.lua`: Kitty protocol encoding, placement, and tmux wrapping.

Terminal image placement and tmux passthrough require manual visual verification.
