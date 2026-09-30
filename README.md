# nvim-extras

A collection of independent Neovim Lua modules for rendering Markdown math
and tables. The repository has no global setup, and installing it does not
enable any module.

## Modules

### `latex_renderer`

Renders Markdown display math as transparent images through the Kitty graphics
protocol and inline math as Unicode extmarks.

```lua
require("latex_renderer").setup({
  scale = 0.8,
})
```

Full rendering requires Neovim 0.12, `nvim-treesitter` with the `markdown`,
`markdown_inline`, and `latex` parsers, `pdflatex`, ImageMagick's `magick`, and
`utftex`. The terminal must support Kitty graphics; tmux also needs passthrough
enabled. See [`lua/latex_renderer/README.md`](lua/latex_renderer/README.md) for
required TeX packages, behavior, and configuration.

### `markdown_table_renderer`

Renders GFM pipe tables with concealed source lines and wrapped virtual lines,
while leaving the Markdown buffer unchanged.

```lua
require("markdown_table_renderer").setup({
  max_width_ratio = 0.95,
  min_col_width = 6,
  max_col_width = 40,
})
```

This module requires Neovim 0.11 or newer and `nvim-treesitter` with the
`markdown` and `markdown_inline` parsers. See
[`lua/markdown_table_renderer/README.md`](lua/markdown_table_renderer/README.md)
for behavior and limitations.

## Installation

Add the repository with the Neovim package manager of your choice. With
Neovim's built-in package API:

```lua
vim.pack.add({
  "https://github.com/inwonakng/nvim-extras",
})
```

For local development, prepend a checkout directly so changes are available
without reinstalling the package:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/path/to/nvim-extras"))
```

This library does not carry a plugin lockfile. Applications should pin the
revision they consume in their own dependency lockfile.

## License

[MIT](LICENSE)
