# Architecture

nvim-extras is a collection of independent Neovim Lua modules. Installing the
repository adds modules to `runtimepath`; it does not configure or activate any
of them.

Each top-level directory under `lua/` owns its setup, runtime checks, commands,
and documentation. Modules must not require unrelated modules from this
collection. Cooperating renderers may consult an already-loaded module without
loading it or calling its setup. The table renderer reads LaTeX inline results
this way, owns their layout inside cells, and requests that standalone math
decorations stay off table-controlled rows (including revealed source rows).
Display-style math in cells remains source; only inline math participates in cell
layout. Conversion completion queues a table reflow; table attachment, rendering,
and detachment refresh standalone decorations without starting new conversions.
External executables are checked by the module that needs them, so using the
Markdown table renderer alone does not require a TeX installation.

The repository currently exports:

- `latex_renderer`: Markdown math rendered as Unicode and Kitty graphics.
- `markdown_table_renderer`: responsive virtual rendering for GFM pipe tables.

A module should move to a separate repository only when it needs an independent
release lifecycle, package-level dependencies, or separate maintainership.
