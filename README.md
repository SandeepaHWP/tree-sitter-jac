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

**Parses current Jac.** Across the jaseci repository on the jac 0.37.25 grammar
(5,404 `.jac` files), **99.7% parse with zero error nodes**. The remaining files
are jaclang's own negative-test fixtures, written to *fail* compilation. Track
it with `jac run scripts/error-density.jac <corpus-dir> [--sample N] [--triage]`.

Covered: declarations (obj/node/edge/walker/class with access tags, bases and
edge endpoints; abilities with modifiers, event clauses and `abst`; has with
`postinit` and getter/setter/deleter accessors; enum, impl including enum member
bodies, glob and `comptime` globals, test, type, sem), statements (if/elif/else,
while, for-in and `for ... while ... with`, `flow for`, `forever`, `in` region
blocks, try/except/finally, with, match, switch, return/yield/raise/assert/del/
visit/report/disengage, `comptime` if/for/assert, typed context blocks), the
full expression precedence ladder including casts, ownership prefixes
(`own`/`imm`/`lin`/`&mut`), atomic and concurrent (`flow`/`wait`) expressions,
`graph { }` blocks and assign comprehensions, collections and comprehensions,
imports (dotted, relative, string-path/JS, extern declaration blocks,
`impl import` wiring), graph/edge and disconnect operators, object-spatial
filter comprehensions, and `#* ... *#` block comments.

An **external scanner** ([`src/scanner.c`](src/scanner.c)) supplies the
context-sensitive tokens the grammar can't express:

- **f-strings** — `f"...{expr}..."` is split into text + parsed interpolations
  (with format specs, conversions, escapes, triple/raw quotes, and nesting).
- **JSX / view bodies** (`.cl.jac`): elements, attributes/spread, fragments,
  `{expr}` children, and `{ ... }` statement slots such as `{if c { <a/> }}`.
- **`::py::`** inline-Python blocks.

**Known limitations:** two spec forms that no current Jac code uses are
resolved by preference. `async class` reads as an archetype rather than an
`async class def` ability, and `comptime async` reads as ability modifiers rather
than a `comptime async for` loop.

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
tree), not inlined. Every optional part of a sequence also doubles that rule's
productions, so runs of optional keywords (ability and `for` modifiers) are a
single visible repeat rule; the same repeat as a hidden rule exhausts memory.
Regenerate with a memory cap during development (for example
`systemd-run --user --scope -p MemoryMax=3G` + `timeout`) so a structural
mistake fails fast instead of exhausting host memory.

## License

MIT
