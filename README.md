# tree-sitter-jac

A [tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the
[Jac](https://www.jac-lang.org/) programming language — providing fast,
incremental syntax highlighting, code folding, structural selection, and
text objects for editors (Neovim, Helix, Zed, Emacs, …).

## Installation

Your editor's tree-sitter tooling compiles the parser from the committed
`src/parser.c` + `src/scanner.c`, so the only prerequisite is a **C compiler**
on your `PATH` (`cc`/`gcc`/`clang`) — the editor handles the rest. The grammar
uses an external scanner (`src/scanner.c`) for f-strings, JSX, and `::py::`
blocks, so any parser registration must compile **both** source files.

### Neovim

This repo *is* a Neovim plugin: it ships filetype detection
([`ftdetect/`](ftdetect/jac.lua)), an ftplugin ([`ftplugin/`](ftplugin/jac.lua)),
and the queries under [`queries/jac/`](queries/jac) — so installing it provides
everything except the compiled parser, which `nvim-treesitter` builds for you.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jaseci-labs/tree-sitter-jac",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
}
```

Then register and build the parser (the registration call differs slightly
between nvim-treesitter's `master` and `main` branches — the exact snippet is in
[`docs/nvim.md`](docs/nvim.md)) and run `:TSInstall jac`. For `::py::` blocks to
highlight as embedded Python, also `:TSInstall python`.

**Full guide** — parser registration, the `jac` LSP (`jac lsp`), folding/indent,
textobjects, and manual (non-plugin) setup: **[`docs/nvim.md`](docs/nvim.md)**.

### Helix & Zed

See **[`docs/editors.md`](docs/editors.md)** for the Helix `languages.toml`
block and the Zed extension scaffold. Both build the grammar from this repo and
use the queries in `queries/jac/`.

### Other tools / the tree-sitter CLI

The grammar manifest is [`tree-sitter.json`](tree-sitter.json) (scope
`source.jac`, file type `jac`). Any tree-sitter-based tool can consume
`src/parser.c` + `src/scanner.c` + `queries/jac/` directly.

### Zero-config registries (upstream, in progress)

`:TSInstall jac` (and `.jac` highlighting on GitHub) becomes fully automatic
once the grammar lands in each ecosystem's registry — nvim-treesitter,
nvim-lspconfig, Helix, Zed, and GitHub Linguist. Those are pull requests to
third-party repos, tracked in
[#2](https://github.com/jaseci-labs/tree-sitter-jac/issues/2) with ready-to-use
recipes; every artifact they reference already lives here.

## Status

**Parses real-world Jac.** Across the full jaclang corpus (~3,100 `.jac` files)
**~91% parse with zero error nodes** — and since a large share of the remainder
are jaclang's own negative-test fixtures (files written to *fail* compilation),
the pass rate on valid Jac is **~97%**. Track it with
`jac run scripts/error-density.jac <corpus-dir> [--sample N] [--triage]`.

Covered: declarations (obj/node/edge/walker/class with access tags & bases,
abilities with event clauses, has + property accessors, enum + bases, impl,
glob, test, type, sem), statements (if/elif/else, while, for-in / for-to-by,
try/except/finally, with, match, switch, return/yield/raise/assert/del/visit/
report/disengage/global/nonlocal), the full expression precedence ladder
including atomic & concurrent (`flow`/`wait`) expressions, collections &
comprehensions (incl. generators), imports (dotted, relative, string-path/JS),
graph/edge & disconnect operators, and object-spatial filter comprehensions.

An **external scanner** ([`src/scanner.c`](src/scanner.c)) supplies the
context-sensitive tokens the grammar can't express:

- **f-strings** — `f"...{expr}..."` is split into text + parsed interpolations
  (with format specs, conversions, escapes, triple/raw quotes, and nesting).
- **JSX / view bodies** (`.cl.jac`) — elements, attributes/spread, fragments,
  `{expr}` children, and `{ if/for { <jsx> } }` view-body control flow.
- **`::py::`** inline-Python blocks.

**Known gaps (small, tracked follow-ups):**
- **Cast `x as T`** — `as` is reserved for except/with/import bindings to avoid
  pervasive grammar conflicts; bare casts are deferred.
- A few reserved words used as identifiers (e.g. `override = ...`) and some
  `.na` native-only constructs.

## Building from source (contributors)

Only contributors regenerating the grammar need to build; *consumers* compile
the committed `src/parser.c` + `src/scanner.c` via their editor (see
[Installation](#installation)).

Prerequisites: the `jac` release pinned in `.jaclang-version`, installed with
`curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash -s -- --version "$(cat .jaclang-version)"`,
and tree-sitter CLI 0.22.6 (`npm i -g tree-sitter-cli@0.22.6`).

```sh
jac run grammar.jac                        # OSP grammar graph -> src/grammar.json
tree-sitter generate src/grammar.json      # -> src/parser.c
tree-sitter test                           # run the corpus tests in test/corpus/
```

This is a Jac project (`jac.toml`); there is intentionally no `package.json`/npm
manifest. Editor-facing metadata lives in `tree-sitter.json`.

## How the grammar is authored — in Jac

The grammar is **authored in Jac itself**, using object-spatial programming
(OSP). Instead of the conventional `grammar.js`, the grammar is built as an
**ordered graph** — every tree-sitter rule construct is a pure-data `node`,
structure is expressed with ordered child edges, and an **`Emit` walker**
traverses that graph to serialize it to `src/grammar.json`, which
`tree-sitter generate` consumes to produce `src/parser.c`.

```
grammar.jac  ──jac run──▶  src/grammar.json  ──tree-sitter generate──▶  src/parser.c
```

This is possible because tree-sitter's real input contract is `grammar.json`;
`grammar.js` is just the usual way to emit it. Authoring as an ordered OSP
graph relies on Jac's guaranteed connection-order out-edges
([jaseci-labs/jaseci#6785](https://github.com/jaseci-labs/jaseci/issues/6785)),
so `(p ++> Seq())[0] ++> [A, B, C]` connects three child edges that read back in
order. The nodes hold no logic; the `Emit` walker descends on `entry` and builds each
node's serialized form on `exit` (post-order — children before parents), so the
computation travels to the data graph. See [`grammar.jac`](grammar.jac).

### Source of truth & drift detection

The Jac grammar's authoritative EBNF is auto-extracted from the jaclang parser
by `grammar_extract_pass` and published as `jaclang/jac.spec`. This tree-sitter
grammar is a hand-tuned translation of that spec. CI installs the `jac` release
pinned in `.jaclang-version`, regenerates the spec with `jac tool grammar`, and
diffs it against the committed `jac.spec.snapshot`. Bumping the pin therefore
fails CI until the snapshot (and the grammar) are updated to match.

### Engineering note (parse-table size)

tree-sitter builds one LR state machine per *distinct* rule structure, so
inlining a helper (e.g. a name/decorator/code-block fragment) at many call
sites duplicates its states and can blow up table construction. Helpers that
appear in many places — `_name_ref`, `decorator_list`, `block_body` — are
therefore emitted as **shared rules** (hidden where they shouldn't appear in the
tree), not inlined. Regenerate with a memory cap during development
(`ulimit -v` + `timeout`) so a structural mistake fails fast instead of
exhausting host memory.

## License

MIT
