"""Tree-sitter grammar for the Jac programming language, authored in Jac OSP.

The grammar is built as an **object-spatial graph**: every tree-sitter rule
construct is a pure-data `node`, structure is expressed with ordered child
edges, and an `Emit` **walker** traverses the graph to serialize it to
`src/grammar.json`, which `tree-sitter generate` consumes to produce
`src/parser.c`.

Why OSP fits: a tree-sitter grammar is an ordered, nested (and, via rule
references, cyclic) structure -- exactly the shape object-spatial graphs model
well, now that out-edge ordering is a guaranteed OSP semantic (connection
order; jaseci-labs/jaseci#6785). A rule body is built top-down -- create a node,
then descend into its children: `p ++> Seq() ++> [A, B, C]` connects three
child edges in order, and `[here -->]` reads them back in that same order. Serialization is a
genuine walker traversal: `Emit` descends on `entry` and builds each node's
`out` on `exit` -- which fires only after all descendants, i.e. post-order --
so the nodes stay pure data and the algorithm travels to the graph.

Source of truth: the language's own EBNF, auto-extracted from the jaclang
parser by `grammar_extract_pass` and published as `jaclang/jac.spec`. This file
is a hand-tuned translation of that spec into tree-sitter rules.

Build:  jac run grammar.jac        # writes src/grammar.json
        tree-sitter generate src/grammar.json
"""

import json;
import os;

# ===========================================================================
# Grammar node types
#
# Each node mirrors a node in the tree-sitter grammar.json schema. Structural
# children hang off ordered out-edges (generic `++>`); a node's own scalar
# data (a literal value, a field name, a precedence level) lives in `has`
# fields. `emit` folds the subgraph rooted at the node into grammar.json.
# ===========================================================================

# The node types are PURE DATA: structural children hang off ordered out-edges
# (`++>`), scalar data lives in `has` fields, and the serialized grammar.json is
# written onto `out` by the `Emit` walker (below). Keeping the algorithm out of
# the nodes is what makes this object-spatial: a walker carries the computation
# to the data graph, rather than each node serializing itself.

"""Base type for every grammar construct; the `Emit` walker fills `out`."""
node GNode {
    has out: dict[str, any] = {};
}

# NOTE: the scalar fields below carry defaults only to satisfy dataclass field
# ordering (the inherited `out` has a default); construction always supplies
# them explicitly.

"""A literal string token (an anonymous terminal), e.g. "obj"."""
node Lit(GNode) { has value: str = ""; }

"""A regular-expression token."""
node Pat(GNode) { has value: str = ""; }

"""A reference to another rule by name (the $.<name> of grammar.js)."""
node Sym(GNode) { has name: str = ""; }

"""The empty match."""
node Blank(GNode) {}

"""Ordered sequence: A B C (children are the ordered members)."""
node Seq(GNode) {}

"""Alternatives: A | B | C (children are the ordered members)."""
node Choice(GNode) {}

"""Zero or more: A* (one child)."""
node Rep(GNode) {}

"""One or more: A+ (one child)."""
node Rep1(GNode) {}

"""Lexer-level token: treat the contained subrule as a single terminal."""
node Tok(GNode) {}

"""Token that must immediately follow the previous one (no extras between)."""
node ITok(GNode) {}

"""Attach a field name to a child (for queries / tree navigation)."""
node Field(GNode) { has name: str = ""; }

"""Rename a node in the output tree."""
node Alias(GNode) { has name: str = "", named: bool = True; }

"""Precedence wrapper. `kind` selects PREC / PREC_LEFT / PREC_RIGHT / PREC_DYNAMIC."""
node Prec(GNode) { has kind: str = "", level: int = 0; }

# ===========================================================================
# Emit walker -- the serializer
#
# `Emit` folds a grammar subgraph into its grammar.json dict. It descends on
# `entry` (`visit [-->]`, one ability that matches every GNode polymorphically)
# and builds each node's `out` on `exit`. Because a node's `exit` fires only
# after all of its descendants have exited, this is a post-order pass: when a
# parent runs, its children's `out` are already populated, so it just folds
# them in. `emit(n)` dispatches the walker and reads the result back.
# ===========================================================================
walker Emit {
    can descend     with GNode  entry { visit [-->]; }

    can emit_lit    with Lit    exit { here.out = {"type": "STRING", "value": here.value}; }
    can emit_pat    with Pat    exit { here.out = {"type": "PATTERN", "value": here.value}; }
    can emit_sym    with Sym    exit { here.out = {"type": "SYMBOL", "name": here.name}; }
    can emit_blank  with Blank  exit { here.out = {"type": "BLANK"}; }
    can emit_seq    with Seq    exit { here.out = {"type": "SEQ", "members": [k.out for k in [here -->]]}; }
    can emit_choice with Choice exit { here.out = {"type": "CHOICE", "members": [k.out for k in [here -->]]}; }
    can emit_rep    with Rep    exit { here.out = {"type": "REPEAT", "content": [here -->][0].out}; }
    can emit_rep1   with Rep1   exit { here.out = {"type": "REPEAT1", "content": [here -->][0].out}; }
    can emit_tok    with Tok    exit { here.out = {"type": "TOKEN", "content": [here -->][0].out}; }
    can emit_itok   with ITok   exit { here.out = {"type": "IMMEDIATE_TOKEN", "content": [here -->][0].out}; }
    can emit_field  with Field  exit {
        here.out = {"type": "FIELD", "name": here.name, "content": [here -->][0].out};
    }
    can emit_alias  with Alias  exit {
        here.out = {"type": "ALIAS", "value": here.name, "named": here.named, "content": [here -->][0].out};
    }
    can emit_prec   with Prec   exit {
        here.out = {"type": here.kind, "value": here.level, "content": [here -->][0].out};
    }
}

"""Serialize a grammar subgraph to its grammar.json dict by walking it."""
def emit(n: GNode) -> dict[str, any] { n spawn Emit(); return n.out; }

# ===========================================================================
# Shared fragments
#
# Rules are built TOP-DOWN from the node constructors directly: create the
# parent, then descend into its children with `parent ++> Child()` -- `++>`
# returns its target (the RHS node), so the expression IS the fresh child to
# keep building into, and chains left-to-right (`parent ++> Child() ++> Leaf()`);
# a run of leaf/ref children connects in one fan-out, `parent ++> [a, b, c]`.
# Terminals are the pure-data nodes themselves --
# `Lit(value=...)`, `Pat(value=...)`, `Sym(name=...)`, `Blank()` -- and a rule is
# `g ++> Rule(name=...)`. `comma_sep1`/`comma_sep` stay as helpers: each
# builds a multi-node fragment (comma_sep1 shares its `r` child between two
# sequences) used at ~30 expression sites, so neither is an inline constructor.
# ===========================================================================

"""Comma-separated list of one or more `r` (no trailing comma): `r ("," r)*`.
The SAME `r` node is connected under both the outer and the inner sequence (a
shared child), so it serializes by value in each place it appears."""
def comma_sep1(r: GNode) -> GNode {
    outer = Seq();
    outer ++> r;                     # member 1: r
    more  = outer ++> Rep();         # member 2: a Rep -- descend into it
    inner = more ++> Seq();          # Rep's content: a Seq -- descend into it
    inner ++> [Lit(value=","), r];   # that Seq's members: "," then r
    return outer;
}

"""Comma-separated list of zero or more `r`."""
def comma_sep(r: GNode) -> GNode {
    cs = Choice();
    cs ++> [comma_sep1(r), Blank()];
    return cs;
}

# ===========================================================================
# Grammar assembly
#
# A `Rule` is a named node with exactly one child (its body). The `Grammar`
# root connects to its rules in order -- and order matters: tree-sitter treats
# the FIRST rule as the start symbol, so ordered edges carry meaning even here.
# ===========================================================================

node Rule {
    has name: str;
    def body_json -> dict[str, any] { return emit([self -->][0]); }
}

node Grammar {
    has name: str;
    def rules_json -> dict[str, any] { return {r.name: r.body_json() for r in [self -->]}; }
}

# ===========================================================================
# Convenience builders for repeated EBNF shapes.
# ===========================================================================

"""(NAME | KWESC_NAME) -- the two identifier forms. References the SHARED
`_name_ref` rule rather than inlining the 2-way choice at ~50 sites, so
tree-sitter shares those states instead of duplicating them. The rule is
HIDDEN (leading `_`): hidden rules still share parse states, but are elided
from the syntax tree, so `identifier`/`kwesc_name` surface directly under the
parent field (e.g. `has_var name: (identifier)`) instead of being buried one
level down under a `name_ref` node -- which keeps the queries flat."""
def name_ref() -> GNode { return Sym(name="_name_ref"); }

"""access_tag ::= (":" ("pub" | "priv" | "protect")?)?"""
def access_tag() -> GNode {
    at = Choice();
    colon = at ++> Seq();           # member 1: the ":" ...? sequence
    at ++> Blank();                 # member 2: empty
    colon ++> Lit(value=":");
    vis_opt = colon ++> Choice();   # optional visibility keyword
    vis = vis_opt ++> Choice();
    vis_opt ++> Blank();
    vis ++> [Lit(value="pub"), Lit(value="priv"), Lit(value="protect")];
    return at;
}

"""Decorators `(@expr)*`. References the SHARED `decorator_list` rule (rep1,
defined in build_decls) wrapped in opt, so the decorator-prefix states are
built once rather than duplicated across every decl that can carry them."""
def decorators() -> GNode {
    d = Choice();
    d ++> [Sym(name="decorator_list"), Blank()];
    return d;
}

"""A `{ ... }` code block. References the SHARED `block_body` rule (defined in
build_stmts) so tree-sitter builds the statement-list state machine ONCE,
instead of duplicating it at every block site (which exploded the parse
table). `block_body` is rep1 (non-empty); the inner opt handles the empty `{}`."""
def block() -> GNode {
    b = Seq();
    b ++> Lit(value="{");
    bb = b ++> Choice();   # optional block_body
    b ++> Lit(value="}");
    bb ++> [Sym(name="block_body"), Blank()];
    return b;
}

# ===========================================================================
# Tokens
# ===========================================================================

def build_tokens(g: Grammar) -> None {
    g ++> Rule(name="identifier") ++> Tok() ++> Pat(value="[a-zA-Z_][a-zA-Z0-9_]*");
    g ++> Rule(name="kwesc_name") ++> Tok() ++> Pat(value="`[a-zA-Z_][a-zA-Z0-9_]*");
    g ++> Rule(name="_name_ref") ++> Choice() ++> [Sym(name="identifier"), Sym(name="kwesc_name")];
    int_t = g ++> Rule(name="integer") ++> Tok();
    int_t ++> Choice() ++> [
        Pat(value="0[xX][0-9a-fA-F_]+"),
        Pat(value="0[bB][01_]+"),
        Pat(value="0[oO][0-7_]+"),
        Pat(value="[0-9][0-9_]*")
    ];
    flt_t = g ++> Rule(name="float") ++> Tok();
    flt_t ++> Choice() ++> [
        Pat(value="[0-9][0-9_]*\\.[0-9_]*([eE][-+]?[0-9_]+)?"),
        Pat(value="\\.[0-9][0-9_]*([eE][-+]?[0-9_]+)?"),
        Pat(value="[0-9][0-9_]*[eE][-+]?[0-9_]+")
    ];
    # NOTE: f-strings and JSX text need an external C scanner for full fidelity
    # (interpolation / context-sensitive lexing). v0.1 treats strings -- incl.
    # f/r/b-prefixed -- as opaque tokens; interpolated exprs are not yet split
    # out. Tracked as the external-scanner follow-up.
    # Non-f strings only; f-strings (prefix containing f/F) are tokenized by the
    # external scanner into start/content/interpolation/end (see `fstring`).
    str_seq = g ++> Rule(name="string") ++> Tok() ++> Seq();
    str_seq ++> Choice() ++> [Pat(value="[rRbB]+"), Blank()];
    str_seq ++> Choice() ++> [
        Pat(value="\"\"\"([^\"]|\"[^\"]|\"\"[^\"])*\"\"\""),
        Pat(value="'''([^']|'[^']|''[^'])*'''"),
        Pat(value="\"([^\"\\\\\\n]|\\\\.)*\""),
        Pat(value="'([^'\\\\\\n]|\\\\.)*'")
    ];
    g ++> Rule(name="bool") ++> Choice() ++> [Lit(value="True"), Lit(value="False")];
    g ++> Rule(name="null") ++> Lit(value="None");
    g ++> Rule(name="ellipsis") ++> Lit(value="...");
    # `#* ... *#` block comments, or `#` to end of line.
    cm = g ++> Rule(name="comment") ++> Tok() ++> Choice();
    cm ++> Pat(value="#\\*([^*]|\\*+[^*#])*\\*+#");
    cm ++> Pat(value="#([^*\\n].*)?");
    # `pyinline` (jac.spec PYNLINE) is a whole `::py:: ... ::py::` block. Its
    # body is arbitrary Python that the context-free grammar can't delimit, so
    # it is provided by the external scanner (src/scanner.c) and declared in
    # `externals` below -- no rule here.
    bt = [Lit(value=t) for t in [
        "str", "int", "float", "list", "tuple", "set", "dict", "bool", "bytes",
        "any", "type", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
        "f32", "f64"
    ]];
    g ++> Rule(name="builtin_type") ++> Choice() ++> bt;
    sr = [Lit(value=s) for s in [
        "self", "super", "here", "root", "visitor", "props", "init", "postinit"
    ]];
    spr = g ++> Rule(name="special_ref") ++> Choice();
    spr ++> sr;
    # Archetype keywords as values (`[node for node in ns]`); prec -1 so declarations win.
    spr ++> Prec(kind="PREC", level=-1) ++> Choice() ++> [Lit(value=k) for k in ["node", "edge", "walker", "obj", "class", "enum"]];
}

# ===========================================================================
# Expressions
#
# The jac.spec precedence cascade is realized the idiomatic tree-sitter way:
# one `expression` supertype and a `binary_expression` whose alternatives carry
# `prec` levels read straight off the spec's ordering (higher binds tighter).
# ===========================================================================

def build_expr(g: Grammar) -> None {
    expr = g ++> Rule(name="expression") ++> Choice();
    expr ++> [
        Sym(name="binary_expression"),
        Sym(name="cast_expression"),
        Sym(name="unary_expression"),
        Sym(name="ternary_expression"),
        Sym(name="lambda_expression"),
        Sym(name="connect_expression"),
        Sym(name="concurrent_expression"),
        Sym(name="_primary_expression")
    ];

    # (operator, precedence) for left-associative binary operators.
    binops: list[tuple[str, int]] = [
        ("|>", 6), ("<|", 7), ("or", 8), ("and", 9),
        ("==", 11), ("!=", 11), ("<", 11), (">", 11), ("<=", 11), (">=", 11),
        ("in", 11), ("is", 11),
        ("|", 12), ("^", 13), ("&", 14), ("<<", 15), (">>", 15),
        ("+", 16), ("-", 16), ("*", 17), ("/", 17), ("//", 17), ("%", 17),
        ("@", 17), ("by", 4),
        # atomic pipes (jac.spec: atomic_pipe / atomic_pipe_back). Both
        # left-assoc and bind between connect_expression (20) and
        # spawn_expression (23): `:>` looser than `<:`, matching the spec's
        # `atomic_pipe ::= atomic_pipe_back (":>" atomic_pipe_back)*` cascade.
        (":>", 21), ("<:", 22)
    ];
    alts: list[GNode] = [];
    for (op, level) in binops {
        be_p = Prec(kind="PREC_LEFT", level=level);
        be_s = be_p ++> Seq();
        be_s ++> Field(name="left") ++> Sym(name="expression");
        be_s ++> Field(name="operator") ++> Lit(value=op);
        be_s ++> Field(name="right") ++> Sym(name="expression");
        alts.append(be_p);
    }
    # multi-word comparison operators
    for words in [["not", "in"], ["is", "not"]] {
        bw_p = Prec(kind="PREC_LEFT", level=11);
        bw_s = bw_p ++> Seq();
        bw_s ++> Field(name="left") ++> Sym(name="expression");
        bw_s ++> Field(name="operator") ++> Seq() ++> [Lit(value=words[0]), Lit(value=words[1])];
        bw_s ++> Field(name="right") ++> Sym(name="expression");
        alts.append(bw_p);
    }
    # right-associative: ** and walrus
    bpow = Prec(kind="PREC_RIGHT", level=18);
    bpow_s = bpow ++> Seq();
    bpow_s ++> Field(name="left") ++> Sym(name="expression");
    bpow_s ++> Field(name="operator") ++> Lit(value="**");
    bpow_s ++> Field(name="right") ++> Sym(name="expression");
    alts.append(bpow);
    bwal = Prec(kind="PREC_RIGHT", level=3);
    bwal_s = bwal ++> Seq();
    bwal_s ++> Field(name="left") ++> Sym(name="expression");
    bwal_s ++> Field(name="operator") ++> Lit(value=":=");
    bwal_s ++> Field(name="right") ++> Sym(name="expression");
    alts.append(bwal);
    be = g ++> Rule(name="binary_expression") ++> Choice();
    be ++> alts;

    # Cast `x as T` or `x as A | B`: looser than `|`, tighter than comparisons.
    ce_x = g ++> Rule(name="cast_expression") ++> Prec(kind="PREC_LEFT", level=12) ++> Seq();
    ce_x ++> Field(name="value") ++> Sym(name="expression");
    ce_x ++> Lit(value="as");
    ce_x ++> Field(name="type") ++> Sym(name="cast_type");
    ct = g ++> Rule(name="cast_type") ++> Prec(kind="PREC_RIGHT", level=13) ++> Seq();
    ct ++> Sym(name="_primary_expression");
    ct ++> Rep() ++> Prec(kind="PREC_RIGHT", level=13) ++> Seq() ++> [Lit(value="|"), Sym(name="_primary_expression")];

    # Prefix operators. `|>` / `:>` are the prefix pipe-call forms
    # (jac.spec `pipe_call`), e.g. `x = :> uuid4()` -- distinct from their
    # binary (atomic-)pipe roles, disambiguated by the absence of a left operand.
    # NOTE: `**` is intentionally NOT a general prefix operator -- it only ever
    # appears as dict-spread (`{**x}`), call kwargs (`f(**x)`), or a `**param`,
    # each handled by its own rule. Treating it as a unary made `{**x}` match a
    # set element, so `{**base, "k": v}` mis-parsed as a set and broke at `:`.
    # `own` / `imm` / `lin` / `&mut` are ownership prefixes (jac.spec `ref`, `ownership_prefix`).
    uops = [Lit(value=u) for u in ["not", "~", "-", "+", "*", "&", "|>", ":>", "own", "imm", "lin"]];
    ue = g ++> Rule(name="unary_expression") ++> Prec(kind="PREC_RIGHT", level=19);
    ue_s = ue ++> Seq();
    ue_ops = ue_s ++> Field(name="operator") ++> Choice();
    ue_ops ++> uops;
    ue_ops ++> Seq() ++> [Lit(value="&"), Lit(value="mut")];
    ue_s ++> Field(name="operand") ++> Sym(name="expression");

    te = g ++> Rule(name="ternary_expression") ++> Prec(kind="PREC_RIGHT", level=1);
    te_s = te ++> Seq();
    te_s ++> Field(name="consequence") ++> Sym(name="expression");
    te_s ++> Lit(value="if");
    te_s ++> Field(name="condition") ++> Sym(name="expression");
    te_s ++> Lit(value="else");
    te_s ++> Field(name="alternative") ++> Sym(name="expression");

    # flow/wait prefix and await/spawn/ref/unpack prefixes
    conc = g ++> Rule(name="concurrent_expression") ++> Prec(kind="PREC", level=2);
    conc_s = conc ++> Seq();
    conc_s ++> Choice() ++> [Lit(value="flow"), Lit(value="wait")];
    conc_s ++> Sym(name="expression");

    # jac.spec: `"lambda" ("(" func_params ")")? ("->" expression)? "{" code_block_stmts "}"`.
    le = g ++> Rule(name="lambda_expression") ++> Prec(kind="PREC_RIGHT", level=-1);
    le_s = le ++> Seq();
    le_s ++> Lit(value="lambda");
    le_s ++> Choice() ++> [Sym(name="parameter_list"), Blank()];
    le_ret_opt = le_s ++> Choice();
    le_s ++> block();
    le_ret_opt ++> Seq() ++> [Lit(value="->"), Sym(name="expression")];
    le_ret_opt ++> Blank();

    # ---- primary / atoms -------------------------------------------------
    prim = g ++> Rule(name="_primary_expression") ++> Choice();
    prim ++> [
        Sym(name="_atom"),
        Sym(name="call_expression"),
        Sym(name="index_expression"),
        Sym(name="attribute_expression"),
        Sym(name="filter_expression"),
        Sym(name="assign_comprehension"),
        Sym(name="await_expression"),
        Sym(name="spawn_expression"),
        Sym(name="edge_reference")
    ];

    # Object-spatial filter comprehension applied to a primary:
    # `nodes(?score > 5)` / `[-->][?:NodeType, val == 1]` (jac.spec
    # filter_compr_inner / filter_compr_bracket).
    fe = g ++> Rule(name="filter_expression") ++> Prec(kind="PREC_LEFT", level=28);
    fe_s = fe ++> Seq();
    fe_s ++> Field(name="object") ++> Sym(name="_primary_expression");
    fe_alt = fe_s ++> Choice();
    fe_alt ++> Seq() ++> [Lit(value="("), Sym(name="filter_compr"), Lit(value=")")];
    fe_alt ++> Seq() ++> [Lit(value="["), Sym(name="filter_compr"), Lit(value="]")];

    fc = g ++> Rule(name="filter_compr") ++> Seq();
    fc ++> Lit(value="?");
    fc_type_opt = fc ++> Choice();
    fc_comma_opt = fc ++> Choice();
    fc_cs_opt = fc ++> Choice();
    fc_type_opt ++> Seq() ++> [Lit(value=":"), Sym(name="expression")];
    fc_type_opt ++> Blank();
    fc_comma_opt ++> [Lit(value=","), Blank()];
    fc_cs_opt ++> [comma_sep1(Sym(name="expression")), Blank()];

    atom = g ++> Rule(name="_atom") ++> Choice();
    atom ++> [
        name_ref(),
        Sym(name="integer"),
        Sym(name="float"),
        Sym(name="string"),
        Sym(name="multistring"),
        Sym(name="bool"),
        Sym(name="null"),
        Sym(name="ellipsis"),
        Sym(name="builtin_type"),
        Sym(name="special_ref"),
        Sym(name="parenthesized_expression"),
        Sym(name="list"),
        Sym(name="dict"),
        Sym(name="set"),
        Sym(name="comprehension"),
        Sym(name="jsx_element"),
        Sym(name="fstring"),
        Sym(name="graph_expression")
    ];

    # `graph { a ++> b; ... }` builds a detached subgraph.
    gx = g ++> Rule(name="graph_expression") ++> Seq();
    gx ++> [Lit(value="graph"), Lit(value="{")];
    gx_item = gx ++> Rep() ++> Seq();
    gx ++> Lit(value="}");
    gx_item ++> Sym(name="expression");
    gx_item ++> Choice() ++> [Lit(value=";"), Blank()];

    # Implicit concatenation of adjacent string literals, which may mix plain
    # strings and f-strings (jac.spec multistring).
    mstr = g ++> Rule(name="multistring") ++> Prec(kind="PREC", level=2);
    mstr_s = mstr ++> Seq();
    mstr_s ++> Choice() ++> [Sym(name="string"), Sym(name="fstring")];
    mstr_s ++> Rep1() ++> Choice() ++> [Sym(name="string"), Sym(name="fstring")];

    # f-strings: the start/content/end tokens come from the external scanner
    # (src/scanner.c); the grammar parses the embedded `{ expression }`
    # interpolations (with optional `!r`/`!s`/`!a` conversion and `:` format).
    fstr = g ++> Rule(name="fstring") ++> Seq();
    fstr ++> Sym(name="fstring_start");
    fstr ++> Rep() ++> Choice() ++> [Sym(name="fstring_content"), Sym(name="fstring_interpolation")];
    fstr ++> Sym(name="fstring_end");

    # prec 1: in `{x:>{w}}` the inner braces are a nested format field, not a set.
    fi = g ++> Rule(name="fstring_interpolation") ++> Prec(kind="PREC", level=1) ++> Seq();
    fi ++> Lit(value="{");
    fi ++> Field(name="expression") ++> Sym(name="expression");
    fi ++> Choice() ++> [Sym(name="fstring_conversion"), Blank()];
    fi ++> Choice() ++> [Sym(name="fstring_format"), Blank()];
    fi ++> Lit(value="}");

    fcv = g ++> Rule(name="fstring_conversion") ++> Tok();
    fcv_s = fcv ++> Seq();
    fcv_s ++> Lit(value="!");
    fcv_s ++> Choice() ++> [Lit(value="r"), Lit(value="s"), Lit(value="a")];

    ff = g ++> Rule(name="fstring_format") ++> Seq();
    ff ++> Choice() ++> [Lit(value=":"), Lit(value=":>")];
    ff ++> Rep() ++> Choice() ++> [Sym(name="fstring_content"), Sym(name="fstring_interpolation")];

    pe = g ++> Rule(name="parenthesized_expression") ++> Seq();
    pe ++> Lit(value="(");
    pe_inner_opt = pe ++> Choice();
    pe ++> Lit(value=")");
    pe_inner = pe_inner_opt ++> Choice();
    pe_inner_opt ++> Blank();
    pe_inner ++> Seq() ++> [Sym(name="expression"), Sym(name="comprehension_clauses")];   # `(x for x in xs if cond)`
    pe_inner ++> [Sym(name="ability"), Sym(name="yield_expression")];
    pe_tuple = pe_inner ++> Seq();
    pe_tuple ++> comma_sep1(Sym(name="expression"));
    pe_tuple ++> Choice() ++> [Lit(value=","), Blank()];

    ae = g ++> Rule(name="attribute_expression") ++> Prec(kind="PREC_LEFT", level=28);
    ae_s = ae ++> Seq();
    ae_s ++> Field(name="object") ++> Sym(name="_primary_expression");
    ae_s ++> Choice() ++> [Lit(value="."), Lit(value=".>"), Lit(value="<."), Lit(value="?.")];
    ae_s ++> Field(name="attr") ++> Choice() ++> [name_ref(), Sym(name="builtin_type"), Lit(value="getter"), Lit(value="setter"), Lit(value="deleter")];

    call = g ++> Rule(name="call_expression") ++> Prec(kind="PREC_LEFT", level=28);
    call_s = call ++> Seq();
    call_s ++> Field(name="function") ++> Sym(name="_primary_expression");
    call_s ++> Sym(name="argument_list");

    # Assign comprehension: `items(=status="done", count=0)`.
    asc = g ++> Rule(name="assign_comprehension") ++> Prec(kind="PREC_LEFT", level=28) ++> Seq();
    asc ++> Field(name="object") ++> Sym(name="_primary_expression");
    asc ++> [Lit(value="("), Lit(value="=")];
    asc_item = Seq();
    asc_item ++> Field(name="name") ++> name_ref();
    asc_item ++> [Lit(value="="), Sym(name="expression")];
    asc ++> comma_sep(asc_item);
    asc ++> Lit(value=")");

    al = g ++> Rule(name="argument_list") ++> Seq();
    al ++> Lit(value="(");
    al_cs_opt = al ++> Choice();
    al_trail = al ++> Choice();
    al ++> Lit(value=")");
    al_cs_opt ++> [comma_sep1(Sym(name="argument")), Blank()];
    al_trail ++> [Lit(value=","), Blank()];

    arg = g ++> Rule(name="argument") ++> Choice();
    arg_kw = arg ++> Seq();
    arg ++> Seq() ++> [Lit(value="**"), Sym(name="expression")];
    arg ++> Seq() ++> [Lit(value="*"), Sym(name="expression")];
    arg_bare = arg ++> Seq();
    arg_kw ++> Field(name="name") ++> Choice() ++> [name_ref(), Sym(name="builtin_type"), Sym(name="special_ref")];
    arg_kw ++> [Lit(value="="), Sym(name="expression")];
    arg_bare ++> Sym(name="expression");
    # bare expression, optionally a generator expression `f(x for x in y)`
    arg_bare ++> Choice() ++> [Sym(name="comprehension_clauses"), Blank()];

    ie = g ++> Rule(name="index_expression") ++> Prec(kind="PREC_LEFT", level=28);
    ie_s = ie ++> Seq();
    ie_s ++> Field(name="object") ++> Sym(name="_primary_expression");
    ie_s ++> Choice() ++> [Lit(value="?"), Blank()];
    ie_s ++> [Lit(value="["), Sym(name="slice"), Lit(value="]")];

    sl = g ++> Rule(name="slice") ++> Choice();
    sl_full = sl ++> Seq();
    sl ++> comma_sep1(Sym(name="expression"));
    sl_full ++> Choice() ++> [Sym(name="expression"), Blank()];
    sl_full ++> Lit(value=":");
    sl_full ++> Choice() ++> [Sym(name="expression"), Blank()];
    sl_step_opt = sl_full ++> Choice();
    sl_step = sl_step_opt ++> Seq();
    sl_step_opt ++> Blank();
    sl_step ++> Lit(value=":");
    sl_step ++> Choice() ++> [Sym(name="expression"), Blank()];

    awa = g ++> Rule(name="await_expression") ++> Prec(kind="PREC", level=26);
    awa_s = awa ++> Seq();
    awa_s ++> [Lit(value="await"), Sym(name="expression")];

    spw = g ++> Rule(name="spawn_expression") ++> Choice();
    spw_s = spw ++> Prec(kind="PREC_LEFT", level=23) ++> Seq();
    spw_s ++> [Sym(name="expression"), Lit(value="spawn"), Sym(name="expression")];
    spw_pre = spw ++> Prec(kind="PREC_RIGHT", level=22) ++> Seq();
    spw_pre ++> [Lit(value="spawn"), Sym(name="expression")];
}

# ===========================================================================
# Collections & comprehensions
# ===========================================================================

def build_collections(g: Grammar) -> None {
    # list ::= "[" opt(comma_sep1(expr)) opt(",") "]"
    li = g ++> Rule(name="list") ++> Seq();
    li ++> Lit(value="[");
    li_items = li ++> Choice();
    li_trail = li ++> Choice();
    li ++> Lit(value="]");
    li_items ++> [comma_sep1(Sym(name="expression")), Blank()];
    li_trail ++> [Lit(value=","), Blank()];

    # set ::= "{" comma_sep1(expr) opt(",") "}"
    se = g ++> Rule(name="set") ++> Seq();
    se ++> [Lit(value="{"), comma_sep1(Sym(name="expression"))];
    se_trail = se ++> Choice();
    se ++> Lit(value="}");
    se_trail ++> [Lit(value=","), Blank()];

    # dict ::= "{" opt(comma_sep1(dict_entry)) opt(",") "}"
    di = g ++> Rule(name="dict") ++> Seq();
    di ++> Lit(value="{");
    di_items = di ++> Choice();
    di_trail = di ++> Choice();
    di ++> Lit(value="}");
    di_items ++> [comma_sep1(Sym(name="dict_entry")), Blank()];
    di_trail ++> [Lit(value=","), Blank()];

    # dict_entry ::= "**" expr | key=expr ":" value=expr
    de = g ++> Rule(name="dict_entry") ++> Choice();
    de ++> Seq() ++> [Lit(value="**"), Sym(name="expression")];
    de_kv = de ++> Seq();
    de_kv ++> Field(name="key") ++> Sym(name="expression");
    de_kv ++> Lit(value=":");
    de_kv ++> Field(name="value") ++> Sym(name="expression");

    # comprehension ::= list_comprehension | dict_comprehension | set_comprehension
    g ++> Rule(name="comprehension") ++> Choice() ++> [Sym(name="list_comprehension"), Sym(name="dict_comprehension"), Sym(name="set_comprehension")];

    # list_comprehension ::= "[" expr comprehension_clauses "]"
    g ++> Rule(name="list_comprehension") ++> Seq() ++> [Lit(value="["), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="]")];

    # set_comprehension ::= "{" expr comprehension_clauses "}"
    g ++> Rule(name="set_comprehension") ++> Seq() ++> [Lit(value="{"), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="}")];

    # dict_comprehension ::= "{" expr ":" expr comprehension_clauses "}"
    g ++> Rule(name="dict_comprehension") ++> Seq() ++> [Lit(value="{"), Sym(name="expression"), Lit(value=":"), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="}")];

    # jac.spec: comprehension_clauses ::= compr_clause+ where each clause is a
    # `for X in Y` followed by zero+ trailing `if`s. Clauses INTERLEAVE
    # (`for a in b if c for d in e`), so this is rep1 of (for + ifs), not "all
    # fors then all ifs".
    cc = g ++> Rule(name="comprehension_clauses") ++> Rep1();
    cc_clause = cc ++> Seq();
    cc_clause ++> Sym(name="for_in_clause");
    cc_clause ++> Rep() ++> Sym(name="if_clause");

    # The target is a primary-expression list (jac.spec uses `atomic_chain`),
    # NOT a full expression -- a full expression would swallow the `in`
    # separator as a binary `in` comparison (`for (i in y)`). Comma-separated to
    # allow tuple targets `for k, v in ...`.
    # prec 2 (> ternary's 1) so a trailing `if` reduces the iterable and
    # attaches as a comprehension filter instead of starting an (else-less)
    # ternary on the iterable.
    fic_s = g ++> Rule(name="for_in_clause") ++> Prec(kind="PREC_RIGHT", level=2) ++> Seq();
    fic_s ++> Choice() ++> [Lit(value="async"), Blank()];
    fic_s ++> Lit(value="for");
    fic_s ++> Field(name="left") ++> comma_sep1(Sym(name="_primary_expression"));
    fic_s ++> Lit(value="in");
    fic_s ++> Field(name="right") ++> Sym(name="expression");

    # if_clause ::= "if" expr
    # prec 2 (above ternary): a following `if` starts another filter.
    g ++> Rule(name="if_clause") ++> Prec(kind="PREC", level=2) ++> Seq() ++> [Lit(value="if"), Sym(name="expression")];
}

# ===========================================================================
# Graph / object-spatial operators
# ===========================================================================

# ===========================================================================
# JSX / view bodies (.cl.jac client UIs)
# ===========================================================================
#
# A `jsx_element` is an atom, so the opening `<` is unambiguous: at an atom
# position only JSX can start with `<`, whereas the binary `<` operator only
# appears in infix position (a disjoint parser state). The only token the CFG
# cannot express is the raw inter-tag text, supplied by the external scanner as
# `jsx_text` (src/scanner.c).
def build_jsx(g: Grammar) -> None {
    # jsx_element ::= "<" ( fragment | named )
    je = g ++> Rule(name="jsx_element") ++> Seq();
    je ++> Lit(value="<");
    je_body = je ++> Choice();
    # fragment:  <> children </>
    je_frag = je_body ++> Seq();
    je_frag ++> Lit(value=">");
    je_frag ++> Rep() ++> Sym(name="jsx_child");
    je_frag ++> [Lit(value="<"), Lit(value="/"), Lit(value=">")];
    # named element
    je_named = je_body ++> Seq();
    je_named ++> Field(name="name") ++> Sym(name="jsx_name");
    je_named ++> Rep() ++> Sym(name="jsx_attribute");
    je_close = je_named ++> Choice();
    je_close ++> Seq() ++> [Lit(value="/"), Lit(value=">")];                          # self-closing
    je_open = je_close ++> Seq();                                         # open ... close
    je_open ++> Lit(value=">");
    je_open ++> Rep() ++> Sym(name="jsx_child");
    je_open ++> [Lit(value="<"), Lit(value="/")];
    je_open ++> Choice() ++> [Sym(name="jsx_name"), Blank()];
    je_open ++> Lit(value=">");

    # Tag / attribute name: identifier, dotted member (`Foo.Bar`), or hyphenated
    # (`aria-label`); `@` is the raw-passthrough tag.
    jn = g ++> Rule(name="jsx_name") ++> Seq();
    jn_head = jn ++> Choice();
    jn_head ++> Sym(name="identifier");
    jn_dyn = jn_head ++> Seq();
    jn_dyn ++> Lit(value="@");
    jn_dyn_name = ITok();
    jn_dyn_name ++> Pat(value="[a-zA-Z_][a-zA-Z0-9_]*");
    jn_dyn ++> Choice() ++> [jn_dyn_name, Blank()];
    jn_rest = jn ++> Rep();
    jn_part = jn_rest ++> Seq();
    jn_part ++> Choice() ++> [Lit(value="."), Lit(value="-")];
    jn_part ++> Sym(name="identifier");

    # jsx_attribute ::= name=jsx_name opt("=" value) | shorthand/spread
    ja = g ++> Rule(name="jsx_attribute") ++> Choice();
    ja_attr = ja ++> Seq();
    # shorthand / spread:  {expr} | {...expr} | {**expr}. The `**expr` form
    # parses as a prefix unary expression; `...` (rest/spread) is an
    # explicit optional prefix.
    ja_spread = ja ++> Seq();
    ja_attr ++> Field(name="name") ++> Sym(name="jsx_name");
    ja_eq_opt = ja_attr ++> Choice();
    ja_eq = ja_eq_opt ++> Seq();
    ja_eq_opt ++> Blank();
    ja_eq ++> Lit(value="=");
    ja_val_choice = ja_eq ++> Field(name="value") ++> Choice();
    ja_val_choice ++> Sym(name="string");
    ja_val_choice ++> Seq() ++> [Lit(value="{"), Sym(name="expression"), Lit(value="}")];
    ja_spread ++> Lit(value="{");
    ja_spread ++> Choice() ++> [Lit(value="..."), Blank()];
    ja_spread ++> [Sym(name="expression"), Lit(value="}")];

    g ++> Rule(name="jsx_child") ++> Choice() ++> [Sym(name="jsx_text"), Sym(name="jsx_element"), Sym(name="jsx_expression")];

    # A `{...}` JSX child: a single value (`{count}`) or a block of statements
    # (`{if cond { <a/> } else { <b/> }}`); prec 1 prefers the value reading.
    jx = g ++> Rule(name="jsx_expression") ++> Choice();
    jx_val = jx ++> Prec(kind="PREC", level=1) ++> Seq();
    jx_val ++> [Lit(value="{"), Sym(name="expression"), Lit(value="}")];
    jx_stmts = jx ++> Seq();
    jx_stmts ++> Lit(value="{");
    jx_stmts ++> Choice() ++> [Sym(name="block_body"), Blank()];
    jx_stmts ++> Lit(value="}");
}

def build_edges(g: Grammar) -> None {
    # connect_expression ::= precl(20, left=expression op=connect_op right=expression)
    ce = g ++> Rule(name="connect_expression") ++> Prec(kind="PREC_LEFT", level=20);
    ces = ce ++> Seq();
    ces ++> Field(name="left")  ++> Sym(name="expression");
    ces ++> Field(name="op")    ++> Sym(name="connect_op");
    ces ++> Field(name="right") ++> Sym(name="expression");

    # connect_op ::= "++>" | "<++" | "<++>" | typed-fwd | typed-back | "del" edge_op
    co = g ++> Rule(name="connect_op") ++> Choice();
    co ++> [Lit(value="++>"), Lit(value="<++"), Lit(value="<++>")];
    co_a = co ++> Seq();
    co_b = co ++> Seq();
    # disconnect: `a del --> b` (jac.spec connect_op `"del" edge_op_ref`).
    co ++> Seq() ++> [Lit(value="del"), Sym(name="edge_op")];
    co_a ++> [Lit(value="+>:"), Sym(name="expression")];
    co_a_opt = co_a ++> Choice();
    co_a ++> Lit(value=":+>");
    co_a_opt ++> Seq() ++> [Lit(value=":"), Sym(name="connect_args")];
    co_a_opt ++> Blank();
    co_b ++> [Lit(value="<+:"), Sym(name="expression")];
    co_b_opt = co_b ++> Choice();
    co_b ++> Choice() ++> [Lit(value=":<+"), Lit(value=":+>")];
    co_b_opt ++> Seq() ++> [Lit(value=":"), Sym(name="connect_args")];
    co_b_opt ++> Blank();

    # Edge attributes on a typed connect: `+>: E : weight=1, kind="x" :+>`.
    ca_item = Seq();
    ca_item ++> Field(name="name") ++> name_ref();
    ca_item ++> [Lit(value="="), Sym(name="expression")];
    cargs = g ++> Rule(name="connect_args") ++> Seq();
    cargs ++> comma_sep1(ca_item);
    cargs ++> Choice() ++> [Lit(value=","), Blank()];

    # edge_reference ::= "[" opt(edge|node) opt(expr) rep1(edge_op opt(filter)) opt(filter) "]"
    er = g ++> Rule(name="edge_reference") ++> Seq();
    er ++> Lit(value="[");
    er_en_opt = er ++> Choice();
    er_e_opt = er ++> Choice();
    er_hops = er ++> Rep1();
    er ++> Lit(value="]");
    er_en_opt ++> Choice() ++> [Lit(value="edge"), Lit(value="node")];
    er_en_opt ++> Blank();
    er_e_opt ++> [Sym(name="expression"), Blank()];
    er_hop = er_hops ++> Seq();
    er_hop ++> Sym(name="edge_op");
    er_hop ++> Choice() ++> [Sym(name="edge_filter"), Sym(name="_primary_expression"), Blank()];

    # edge_op ::= "-->" | "<--" | "<-->" | typed-fwd | typed-back
    eo = g ++> Rule(name="edge_op") ++> Choice();
    eo ++> [Lit(value="-->"), Lit(value="<--"), Lit(value="<-->")];
    eo_a = eo ++> Seq();
    eo_b = eo ++> Seq();
    eo_a ++> Lit(value="->:");
    eo_a ++> Choice() ++> [name_ref(), Blank()];
    eo_a_colon_opt = eo_a ++> Choice();
    eo_a ++> Lit(value=":->");
    eo_a_colon = eo_a_colon_opt ++> Seq();
    eo_a_colon_opt ++> Blank();
    eo_a_colon ++> Lit(value=":");
    eo_a_colon ++> Choice() ++> [comma_sep1(Sym(name="expression")), Blank()];
    eo_b ++> Lit(value="<-:");
    eo_b ++> Choice() ++> [name_ref(), Blank()];
    eo_b_colon_opt = eo_b ++> Choice();
    eo_b ++> Lit(value=":<-");
    eo_b_colon = eo_b_colon_opt ++> Seq();
    eo_b_colon_opt ++> Blank();
    eo_b_colon ++> Lit(value=":");
    eo_b_colon ++> Choice() ++> [comma_sep1(Sym(name="expression")), Blank()];

    # edge_filter ::= "[" opt("?" opt(":" expr)) opt(comma_sep1(expr)) "]"
    ef = g ++> Rule(name="edge_filter") ++> Prec(kind="PREC", level=1) ++> Seq();
    ef ++> Lit(value="[");
    ef_q_opt = ef ++> Choice();
    ef_cs_opt = ef ++> Choice();
    ef ++> Lit(value="]");
    ef_q = ef_q_opt ++> Seq();
    ef_q_opt ++> Blank();
    ef_q ++> Lit(value="?");
    ef_q_in_opt = ef_q ++> Choice();
    ef_q_in_opt ++> Seq() ++> [Lit(value=":"), Sym(name="expression")];
    ef_q_in_opt ++> Blank();
    ef_q ++> Choice() ++> [Lit(value=","), Blank()];
    ef_cs_opt ++> [comma_sep1(Sym(name="expression")), Blank()];
}

# ===========================================================================
# Statements
# ===========================================================================

def build_stmts(g: Grammar) -> None {
    # Every statement self-terminates (own `;`, or ends in a block), so the
    # block body is just a sequence of statements -- no per-statement opt(";"),
    # which would otherwise fight each statement's own terminator.
    # A block may end in a bare expression without `;`, e.g. `lambda (c: T) -> T { c }`.
    bb = g ++> Rule(name="block_body") ++> Choice();
    bb_stmts = bb ++> Seq();
    bb ++> Field(name="tail") ++> Sym(name="expression");
    bb_stmts ++> Rep1() ++> Sym(name="statement");
    bb_tail_opt = bb_stmts ++> Choice();
    bb_tail_opt ++> Field(name="tail") ++> Sym(name="expression");
    bb_tail_opt ++> Blank();
    stmt = g ++> Rule(name="statement") ++> Choice();
    stmt ++> [
        Sym(name="if_statement"),
        Sym(name="while_statement"),
        Sym(name="for_statement"),
        Sym(name="forever_statement"),
        Sym(name="open_statement"),
        Sym(name="try_statement"),
        Sym(name="with_statement"),
        Sym(name="match_statement"),
        Sym(name="switch_statement"),
        Sym(name="return_statement"),
        Sym(name="yield_statement"),
        Sym(name="raise_statement"),
        Sym(name="assert_statement"),
        Sym(name="delete_statement"),
        Sym(name="control_statement"),
        Sym(name="visit_statement"),
        Sym(name="report_statement"),
        Sym(name="disengage_statement"),
        Sym(name="import_statement"),
        Sym(name="global_var"),
        Sym(name="has_statement"),
        Sym(name="ability"),
        Sym(name="archetype"),
        Sym(name="impl"),
        Sym(name="typed_context_block"),
        Sym(name="documented_declaration"),
        Sym(name="pyinline"),
        Sym(name="expression_statement"),
        Sym(name="jsx_statement"),
        Sym(name="empty_statement")
    ];
    # A JSX element starting a statement is a view statement; `;` is optional.
    jst = g ++> Rule(name="jsx_statement") ++> Prec(kind="PREC_RIGHT", level=0) ++> Seq();
    jst ++> Sym(name="jsx_element");
    jst ++> Choice() ++> [Lit(value=";"), Blank()];
    # A lone `;` (e.g. an empty `else { ; }` / `except E { ; }` body).
    g ++> Rule(name="empty_statement") ++> Lit(value=";");
    # A single rule covering expression / assignment / augmented-assignment.
    # Parsing the leading expression once, then an OPTIONAL assignment tail,
    # avoids a GLR conflict over the whole expression grammar (which exploded
    # the parse table). The next token (`=`/`:`/augop vs `;`) decides the tail.
    augops = [Lit(value=a) for a in ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "@=",
              "&=", "|=", "^=", "<<=", ">>="]];
    es = g ++> Rule(name="expression_statement") ++> Seq();
    es ++> Field(name="left") ++> Sym(name="expression");
    es_tail_opt = es ++> Choice();
    es ++> Lit(value=";");
    es_tail = es_tail_opt ++> Choice();
    es_tail_opt ++> Blank();
    es_ann = es_tail ++> Seq();   # `x: T`, `x: T = v` -- type annotation + value(s)
    es_asn = es_tail ++> Rep1();  # `x = v`, `x = v = w` -- chained assignment
    es_aug = es_tail ++> Seq();   # `x += v` -- augmented assignment
    es_ann ++> Lit(value=":");
    es_ann ++> Field(name="type") ++> Sym(name="expression");
    es_ann_vals_opt = es_ann ++> Choice();
    es_ann_vals = es_ann_vals_opt ++> Rep1();
    es_ann_vals_opt ++> Blank();
    es_ann_eq = es_ann_vals ++> Seq();
    es_ann_eq ++> Lit(value="=");
    es_ann_eq ++> Field(name="right") ++> Sym(name="expression");
    es_asn_eq = es_asn ++> Seq();
    es_asn_eq ++> Lit(value="=");
    es_asn_eq ++> Field(name="right") ++> Choice() ++> [Sym(name="expression"), Sym(name="yield_expression")];
    es_aug_op = es_aug ++> Field(name="operator") ++> Choice();
    es_aug_op ++> augops;
    es_aug ++> Field(name="right") ++> Sym(name="expression");

    # if_statement ::= "if" condition=expr block opt(elif_clause | else_clause)
    if_s = g ++> Rule(name="if_statement") ++> Seq();
    if_s ++> Choice() ++> [Lit(value="comptime"), Blank()];
    if_s ++> Lit(value="if");
    if_s ++> Field(name="condition") ++> Sym(name="expression");
    if_s ++> block();
    if_cont_opt = if_s ++> Choice();
    if_cont_opt ++> Choice() ++> [Sym(name="elif_clause"), Sym(name="else_clause")];
    if_cont_opt ++> Blank();

    elif_s = g ++> Rule(name="elif_clause") ++> Seq();
    elif_s ++> Lit(value="elif");
    elif_s ++> Field(name="condition") ++> Sym(name="expression");
    elif_s ++> block();
    elif_cont_opt = elif_s ++> Choice();
    elif_cont_opt ++> Choice() ++> [Sym(name="elif_clause"), Sym(name="else_clause")];
    elif_cont_opt ++> Blank();

    else_s = g ++> Rule(name="else_clause") ++> Seq();
    else_s ++> [Lit(value="else"), block()];

    wh = g ++> Rule(name="while_statement") ++> Seq();
    wh ++> Lit(value="while");
    wh ++> Field(name="condition") ++> Sym(name="expression");
    wh ++> block();
    wh ++> Choice() ++> [Sym(name="else_clause"), Blank()];

    # The target is a primary-expression list, not a full expression, so the
    # `in` separator isn't swallowed as a binary `in` comparison (which broke
    # iterables like `node.bases or []`). Comma-separated for `for k, v in ...`.
    for_s = g ++> Rule(name="for_statement") ++> Seq();
    for_s ++> Choice() ++> [Sym(name="for_modifiers"), Blank()];
    for_s ++> Lit(value="for");
    fmods = g ++> Rule(name="for_modifiers") ++> Rep1() ++> Choice();
    fmods ++> [Lit(value="comptime"), Lit(value="async"), Lit(value="flow")];
    for_s ++> Field(name="target") ++> comma_sep1(Sym(name="_primary_expression"));
    for_head = for_s ++> Choice();
    for_s ++> block();
    for_s ++> Choice() ++> [Sym(name="else_clause"), Blank()];
    for_in = for_head ++> Seq();
    for_in ++> Lit(value="in");
    for_in ++> Field(name="iter") ++> Sym(name="expression");
    # Counted loop: `for i = 0 while i < n with i += 1 { ... }`.
    for_count = for_head ++> Seq();
    for_count ++> Lit(value="=");
    for_count ++> Field(name="init") ++> Sym(name="expression");
    for_count ++> Lit(value="while");
    for_count ++> Field(name="condition") ++> Sym(name="expression");
    for_count ++> Lit(value="with");
    for_count ++> Field(name="update") ++> Sym(name="for_update");
    fu = g ++> Rule(name="for_update") ++> Seq();
    fu ++> Field(name="left") ++> Sym(name="_primary_expression");
    fu_op = fu ++> Field(name="operator") ++> Choice();
    fu_op ++> [Lit(value=a) for a in ["=", "+=", "-=", "*=", "/=", "//=", "%=", "**=", "@=",
               "&=", "|=", "^=", "<<=", ">>="]];
    fu ++> Field(name="right") ++> Sym(name="expression");

    g ++> Rule(name="forever_statement") ++> Seq() ++> [Lit(value="forever"), block()];

    # A docstring directly before a local declaration; prec 1 so `"doc" @dec` is not matmul.
    ddoc = g ++> Rule(name="documented_declaration") ++> Prec(kind="PREC", level=1) ++> Seq();
    ddoc ++> Sym(name="string");
    ddoc ++> Choice() ++> [Sym(name="ability"), Sym(name="archetype"), Sym(name="enum"), Sym(name="impl")];

    # Typed context block in a walker: `->Item { ... }`.
    tcb = g ++> Rule(name="typed_context_block") ++> Seq();
    tcb ++> Lit(value="->");
    tcb ++> Field(name="type") ++> Sym(name="expression");
    tcb ++> block();

    # Region block: `in Region() { ... }`.
    opn = g ++> Rule(name="open_statement") ++> Seq();
    opn ++> Lit(value="in");
    opn ++> Field(name="region") ++> Sym(name="expression");
    opn ++> block();

    # try_statement ::= "try" block opt("awaiting" block) rep(except) opt(else) opt("finally" block)
    try_s = g ++> Rule(name="try_statement") ++> Seq();
    try_s ++> [Lit(value="try"), block()];
    try_await_opt = try_s ++> Choice();
    try_excepts = try_s ++> Rep();
    try_else = try_s ++> Choice();
    try_finally_opt = try_s ++> Choice();
    try_await_opt ++> Seq() ++> [Lit(value="awaiting"), block()];
    try_await_opt ++> Blank();
    try_excepts ++> Sym(name="except_clause");
    try_else ++> [Sym(name="else_clause"), Blank()];
    try_finally_opt ++> Seq() ++> [Lit(value="finally"), block()];
    try_finally_opt ++> Blank();

    # prec 1: `except E as e {` binds `e`, it is not a cast.
    exc = g ++> Rule(name="except_clause") ++> Prec(kind="PREC", level=1) ++> Seq();
    exc ++> [Lit(value="except"), Sym(name="expression")];
    exc_as_opt = exc ++> Choice();
    exc ++> block();
    exc_as_opt ++> Seq() ++> [Lit(value="as"), name_ref()];
    exc_as_opt ++> Blank();

    with_item = Seq();
    with_item ++> Sym(name="expression");
    with_as_opt = with_item ++> Choice();
    with_as_opt ++> Seq() ++> [Lit(value="as"), Sym(name="_with_target")];
    # prec 14 (above cast_type): `with x as y {` binds `y`, it is not a cast.
    g ++> Rule(name="_with_target") ++> Prec(kind="PREC", level=14) ++> Sym(name="_primary_expression");
    with_as_opt ++> Blank();
    with_s = g ++> Rule(name="with_statement") ++> Seq();
    with_s ++> Choice() ++> [Lit(value="async"), Blank()];
    with_s ++> [Lit(value="with"), comma_sep1(with_item)];
    with_s ++> block();

    ret = g ++> Rule(name="return_statement") ++> Seq();
    ret ++> Lit(value="return");
    ret ++> Choice() ++> [Sym(name="expression"), Blank()];
    ret ++> Lit(value=";");

    yld = g ++> Rule(name="yield_statement") ++> Seq();
    yld ++> [Sym(name="yield_expression"), Lit(value=";")];
    yx = g ++> Rule(name="yield_expression") ++> Prec(kind="PREC_RIGHT", level=0) ++> Seq();
    yx ++> Lit(value="yield");
    yx ++> Choice() ++> [Lit(value="from"), Blank()];
    yx ++> Choice() ++> [Sym(name="expression"), Blank()];

    rse = g ++> Rule(name="raise_statement") ++> Seq();
    rse ++> Lit(value="raise");
    rse ++> Choice() ++> [Sym(name="expression"), Blank()];
    rse_from_opt = rse ++> Choice();
    rse ++> Lit(value=";");
    rse_from_opt ++> Seq() ++> [Lit(value="from"), Sym(name="expression")];
    rse_from_opt ++> Blank();

    asrt = g ++> Rule(name="assert_statement") ++> Seq();
    asrt ++> Choice() ++> [Lit(value="comptime"), Blank()];
    asrt ++> [Lit(value="assert"), Sym(name="expression")];
    asrt_msg_opt = asrt ++> Choice();
    asrt ++> Lit(value=";");
    asrt_msg_opt ++> Seq() ++> [Lit(value=","), Sym(name="expression")];
    asrt_msg_opt ++> Blank();

    del_s = g ++> Rule(name="delete_statement") ++> Seq();
    del_s ++> [Lit(value="del"), comma_sep1(Sym(name="expression")), Lit(value=";")];

    ctrl = g ++> Rule(name="control_statement") ++> Seq();
    ctrl ++> Choice() ++> [Lit(value="break"), Lit(value="continue"), Lit(value="skip")];
    ctrl ++> Lit(value=";");

    dis = g ++> Rule(name="disengage_statement") ++> Seq();
    dis ++> [Lit(value="disengage"), Lit(value=";")];

    # prec.right so the optional trailing `;` is consumed here rather than left
    # to stand alone as an empty_statement.
    vis = g ++> Rule(name="visit_statement") ++> Prec(kind="PREC_RIGHT", level=1);
    vis_s = vis ++> Seq();
    vis_s ++> Lit(value="visit");
    vis_label_opt = vis_s ++> Choice();
    vis_s ++> Sym(name="expression");
    vis_tail_opt = vis_s ++> Choice();
    vis_label_opt ++> Seq() ++> [Lit(value=":"), Sym(name="expression"), Lit(value=":")];
    vis_label_opt ++> Blank();
    vis_tail_opt ++> Choice() ++> [Sym(name="else_clause"), Lit(value=";")];
    vis_tail_opt ++> Blank();

    rep_s = g ++> Rule(name="report_statement") ++> Seq();
    rep_s ++> [Lit(value="report"), Sym(name="expression"), Lit(value=";")];
}

# ===========================================================================
# Patterns (match / switch)
# ===========================================================================

def build_patterns(g: Grammar) -> None {
    # match_statement ::= "match" expr "{" rep(match_case) "}"
    ms = g ++> Rule(name="match_statement") ++> Seq();
    ms ++> [Lit(value="match"), Sym(name="expression"), Lit(value="{")];
    ms ++> Rep() ++> Sym(name="match_case");
    ms ++> Lit(value="}");

    # match_case ::= "case" pattern opt("if" expr) ":" rep(statement)
    mc = g ++> Rule(name="match_case") ++> Seq();
    mc ++> [Lit(value="case"), Sym(name="pattern")];
    mc_guard_opt = mc ++> Choice();
    mc ++> Lit(value=":");
    mc ++> Rep() ++> Sym(name="statement");
    mc_guard_opt ++> Seq() ++> [Lit(value="if"), Sym(name="expression")];
    mc_guard_opt ++> Blank();

    # pattern ::= or_pattern opt("as" name)
    ptn = g ++> Rule(name="pattern") ++> Seq();
    ptn ++> Sym(name="or_pattern");
    ptn_as_opt = ptn ++> Choice();
    ptn_as_opt ++> Seq() ++> [Lit(value="as"), name_ref()];
    ptn_as_opt ++> Blank();

    # or_pattern ::= closed_pattern rep("|" closed_pattern)
    op = g ++> Rule(name="or_pattern") ++> Seq();
    op ++> Sym(name="closed_pattern");
    op_rest = op ++> Rep();
    op_rest ++> Seq() ++> [Lit(value="|"), Sym(name="closed_pattern")];

    cp = g ++> Rule(name="closed_pattern") ++> Choice();
    cp ++> [Sym(name="bool"), Sym(name="null"), Sym(name="integer"), Sym(name="float"), Sym(name="string"), Sym(name="multistring"),
            Sym(name="sequence_pattern"), Sym(name="tuple_pattern"), Sym(name="mapping_pattern"), Sym(name="class_pattern"),
            Sym(name="capture_pattern")];

    # Use a dotted name (not a full `expression`) so patterns don't overlap the
    # expression grammar (which collided with `atom`).
    dpn = g ++> Rule(name="dotted_pattern_name") ++> Seq();
    dpn ++> name_ref();
    dpn_rest = dpn ++> Rep();
    dpn_rest ++> Seq() ++> [Lit(value="."), name_ref()];

    g ++> Rule(name="capture_pattern") ++> Sym(name="dotted_pattern_name");

    # sequence_pattern ::= "[" comma_sep( "*" name | pattern ) opt(",") "]"
    seqp = g ++> Rule(name="sequence_pattern") ++> Seq();
    seqp ++> Lit(value="[");
    seqp_elem = Choice();
    seqp_elem ++> Seq() ++> [Lit(value="*"), name_ref()];
    seqp_elem ++> Sym(name="pattern");
    seqp ++> comma_sep(seqp_elem);
    seqp_trail = seqp ++> Choice();
    seqp ++> Lit(value="]");
    seqp_trail ++> [Lit(value=","), Blank()];

    tup = g ++> Rule(name="tuple_pattern") ++> Seq();
    tup ++> Lit(value="(");
    tup_elem = Choice();
    tup_elem ++> Seq() ++> [Lit(value="*"), name_ref()];
    tup_elem ++> Sym(name="pattern");
    tup ++> comma_sep(tup_elem);
    tup ++> Choice() ++> [Lit(value=","), Blank()];
    tup ++> Lit(value=")");

    # mapping_pattern ::= "{" comma_sep( "**" name | key ":" pattern ) opt(",") "}"
    mp = g ++> Rule(name="mapping_pattern") ++> Seq();
    mp ++> Lit(value="{");
    mp_elem = Choice();
    mp_elem ++> Seq() ++> [Lit(value="**"), name_ref()];
    mp_kv = mp_elem ++> Seq();
    mp_kv ++> Choice() ++> [Sym(name="integer"), Sym(name="float"), Sym(name="string"), Sym(name="dotted_pattern_name")];
    mp_kv ++> [Lit(value=":"), Sym(name="pattern")];
    mp ++> comma_sep(mp_elem);
    mp_trail = mp ++> Choice();
    mp ++> Lit(value="}");
    mp_trail ++> [Lit(value=","), Blank()];

    # class_pattern ::= dotted_pattern_name "(" comma_sep( name "=" pattern | pattern ) opt(",") ")"
    clp = g ++> Rule(name="class_pattern") ++> Seq();
    clp ++> [Sym(name="dotted_pattern_name"), Lit(value="(")];
    clp_elem = Choice();
    clp_elem ++> Seq() ++> [name_ref(), Lit(value="="), Sym(name="pattern")];
    clp_elem ++> Sym(name="pattern");
    clp ++> comma_sep(clp_elem);
    clp_trail = clp ++> Choice();
    clp ++> Lit(value=")");
    clp_trail ++> [Lit(value=","), Blank()];

    sw = g ++> Rule(name="switch_statement") ++> Seq();
    sw ++> [Lit(value="switch"), Sym(name="expression"), Lit(value="{")];
    sw ++> Rep() ++> Sym(name="switch_case");
    sw ++> Lit(value="}");

    # switch_case ::= ("default" | "case" pattern) ":" rep(statement)
    swc = g ++> Rule(name="switch_case") ++> Seq();
    swc_head = swc ++> Choice();
    swc ++> Lit(value=":");
    swc ++> Rep() ++> Sym(name="statement");
    swc_head ++> Lit(value="default");
    swc_head ++> Seq() ++> [Lit(value="case"), Sym(name="pattern")];
}

# ===========================================================================
# Declarations (archetypes, abilities, has, enum, test, glob, impl, type)
#
# NOTE: jac.spec hoists the obj/node/.../def/can dispatch keyword out of the
# `archetype`/`ability` rules (an extraction artifact). The real .jac surface
# carries the keyword in the declaration, so it is re-added here.
# ===========================================================================

def build_decls(g: Grammar) -> None {
    # decorator_list ::= rep1("@" expr)
    dl = g ++> Rule(name="decorator_list") ++> Rep1();
    dl ++> Seq() ++> [Lit(value="@"), Sym(name="expression")];

    g ++> Rule(name="type_annotation") ++> Sym(name="expression");

    # param ::= opt("*"|"**") (name|special_ref) opt(":" type) opt("=" expr)
    param = g ++> Rule(name="param") ++> Seq();
    param ++> Choice() ++> [Lit(value="comptime"), Blank()];
    param_star_opt = param ++> Choice();
    param_star_opt ++> Choice() ++> [Lit(value="*"), Lit(value="**")];
    param_star_opt ++> Blank();
    param ++> Choice() ++> [name_ref(), Sym(name="special_ref"), Sym(name="builtin_type")];
    param_type_opt = param ++> Choice();
    param_def_opt = param ++> Choice();
    param_type_opt ++> Seq() ++> [Lit(value=":"), Sym(name="type_annotation")];
    param_type_opt ++> Blank();
    param_def_opt ++> Seq() ++> [Lit(value="="), Sym(name="expression")];
    param_def_opt ++> Blank();

    pl = g ++> Rule(name="parameter_list") ++> Seq();
    pl ++> Lit(value="(");
    pl_elem = Choice();
    pl_elem ++> [Lit(value="*"), Lit(value="/"), Sym(name="param")];
    pl ++> comma_sep(pl_elem);
    pl_trail = pl ++> Choice();
    pl ++> Lit(value=")");
    pl_trail ++> [Lit(value=","), Blank()];

    # func_signature ::= parameter_list opt("->" return_type) | "->" return_type
    fs = g ++> Rule(name="func_signature") ++> Choice();
    fs_a = fs ++> Seq();
    fs_b = fs ++> Seq();
    fs_a ++> Sym(name="parameter_list");
    fs_arrow1_opt = fs_a ++> Choice();
    fs_arrow1 = fs_arrow1_opt ++> Seq();
    fs_arrow1_opt ++> Blank();
    fs_arrow1 ++> Lit(value="->");
    fs_arrow1 ++> Field(name="return_type") ++> Sym(name="type_annotation");
    fs_b ++> Lit(value="->");
    fs_b ++> Field(name="return_type") ++> Sym(name="type_annotation");

    # archetype ::= decorators opt("async") kind=... access_tag name=... opt(type_params)
    #               opt("(" bases ")") ( "{" members "}" | ";" )
    # prec 2: `async class` reads as an archetype, not as ability modifiers.
    arch = g ++> Rule(name="archetype") ++> Prec(kind="PREC", level=2) ++> Seq();
    arch ++> decorators();
    arch ++> Choice() ++> [Lit(value="async"), Blank()];
    arch ++> Field(name="kind") ++> Choice() ++> [Lit(value="obj"), Lit(value="node"), Lit(value="edge"), Lit(value="walker"), Lit(value="class")];
    arch ++> access_tag();
    arch ++> Field(name="name") ++> name_ref();
    arch ++> Choice() ++> [Sym(name="type_params"), Blank()];
    arch ++> Choice() ++> [Sym(name="_archetype_head"), Blank()];
    arch_body = arch ++> Choice();
    arch_block = arch_body ++> Seq();
    arch_body ++> Lit(value=";");
    arch_block ++> Lit(value="{");
    arch_block ++> Rep() ++> Sym(name="archetype_member");
    arch_block ++> Lit(value="}");

    # Bases `(A, B)` and/or edge endpoints `: any --> any`, as one optional part.
    ahead = g ++> Rule(name="_archetype_head") ++> Choice();
    ahead_bases = Seq();
    ahead_bases ++> Lit(value="(");
    ahead_bases ++> Choice() ++> [comma_sep1(Sym(name="argument")), Blank()];
    ahead_bases ++> Lit(value=")");
    ahead_ends = Seq();
    ahead_ends ++> Lit(value=":");
    ahead_ends ++> Field(name="source") ++> Sym(name="expression");
    ahead_ends ++> Lit(value="-->");
    ahead_ends ++> Field(name="target") ++> Sym(name="expression");
    ahead ++> [ahead_bases, ahead_ends];
    ahead ++> Seq() ++> [ahead_bases, ahead_ends];

    am = g ++> Rule(name="archetype_member") ++> Choice();
    am ++> [Sym(name="has_statement"), Sym(name="ability"), Sym(name="archetype"),
            Sym(name="enum"), Sym(name="impl"), Sym(name="with_entry"),
            Sym(name="global_var"), Sym(name="pyinline"), Sym(name="expression_statement")];
    # prec 1: a string member is a docstring, not an expression statement.
    am_str = am ++> Prec(kind="PREC", level=1) ++> Seq();
    am_str ++> Sym(name="string");
    am_str ++> Choice() ++> [Lit(value=";"), Blank()];

    we = g ++> Rule(name="with_entry") ++> Seq();
    we ++> Lit(value="with");
    we_ee_opt = we ++> Choice();
    we ++> block();
    we_ee_opt ++> Choice() ++> [Lit(value="entry"), Lit(value="exit")];
    we_ee_opt ++> Blank();

    # One shared modifier run: separate optionals would multiply the ability productions.
    # prec 1: `comptime async` reads as ability modifiers rather than a for prefix.
    mods = g ++> Rule(name="ability_modifiers") ++> Rep1() ++> Prec(kind="PREC", level=1) ++> Choice();
    mods ++> [Lit(value="comptime"), Lit(value="override"), Lit(value="class"), Lit(value="static"), Lit(value="async")];

    # ability ::= decorators opt(modifiers) kind=(def|can)
    #             access_tag opt(name) opt(type_params) opt(event_clause|func_signature)
    #             ( block | opt("abst") ";" | "by" expr ";" )
    ab = g ++> Rule(name="ability") ++> Seq();
    ab ++> decorators();
    ab ++> Choice() ++> [Sym(name="ability_modifiers"), Blank()];
    ab ++> Field(name="kind") ++> Choice() ++> [Lit(value="def"), Lit(value="can")];
    ab ++> access_tag();
    ab_name_opt = ab ++> Choice();
    ab ++> Choice() ++> [Sym(name="type_params"), Blank()];
    ab_sig_opt = ab ++> Choice();
    ab_body = ab ++> Choice();
    ab_name_opt ++> Field(name="name") ++> name_ref();
    ab_name_opt ++> Blank();
    ab_sig_opt ++> Choice() ++> [Sym(name="event_clause"), Sym(name="func_signature")];
    ab_sig_opt ++> Blank();
    ab_body ++> block();
    ab_decl = ab_body ++> Seq();
    ab_body ++> Seq() ++> [Lit(value="by"), Sym(name="expression"), Lit(value=";")];
    ab_decl ++> Choice() ++> [Lit(value="abst"), Blank()];
    ab_decl ++> Lit(value=";");

    # Ability event signature: `with <NodeType> entry|exit` (object-spatial
    # dispatch), e.g. `can create with Root entry { ... }`. The trailing
    # entry/exit keyword can't be part of the expression, so it is consumed
    # explicitly after it.
    ec = g ++> Rule(name="event_clause") ++> Seq();
    ec ++> [Lit(value="with"), Sym(name="expression")];
    ec_ee_opt = ec ++> Choice();
    ec_ee_opt ++> Choice() ++> [Lit(value="entry"), Lit(value="exit")];
    ec_ee_opt ++> Blank();

    # prec.right so the optional trailing `;` is consumed here; an accessor-block
    # `has` self-terminates (ends in `}`) so the `;` is optional, like other
    # block-bodied constructs.
    hs = g ++> Rule(name="has_statement") ++> Prec(kind="PREC_RIGHT", level=1);
    hs_s = hs ++> Seq();
    hs_s ++> Choice() ++> [Lit(value="static"), Blank()];
    hs_s ++> [Lit(value="has"), access_tag(), comma_sep1(Sym(name="has_var"))];
    hs_s ++> Choice() ++> [Lit(value=";"), Blank()];

    # prec.right so a following `{` attaches as this field's accessor_block
    # rather than reducing the has_var early.
    hv = g ++> Rule(name="has_var") ++> Prec(kind="PREC_RIGHT", level=1);
    hv_s = hv ++> Seq();
    hv_s ++> Field(name="name") ++> name_ref();
    hv_s ++> Lit(value=":");
    hv_s ++> Field(name="type") ++> Sym(name="type_annotation");
    hv_init_opt = hv_s ++> Choice();
    hv_s ++> Choice() ++> [Sym(name="accessor_block"), Blank()];
    hv_init = hv_init_opt ++> Choice();
    hv_init_opt ++> Blank();
    hv_init ++> Seq() ++> [Lit(value="="), Sym(name="expression")];
    hv_init ++> Lit(value="postinit");

    # Property accessors on a `has` field: `{ getter; setter(value: T); }`.
    acb = g ++> Rule(name="accessor_block") ++> Seq();
    acb ++> Lit(value="{");
    acb ++> Rep() ++> Sym(name="accessor");
    acb ++> Lit(value="}");

    acc = g ++> Rule(name="accessor") ++> Seq();
    acc ++> Field(name="name") ++> Choice() ++> [Lit(value="getter"), Lit(value="setter"), Lit(value="deleter")];
    acc ++> Choice() ++> [Sym(name="parameter_list"), Blank()];
    acc_arrow_opt = acc ++> Choice();
    acc_body = acc ++> Choice();
    acc_arrow = acc_arrow_opt ++> Seq();
    acc_arrow_opt ++> Blank();
    acc_arrow ++> Lit(value="->");
    acc_arrow ++> Field(name="return_type") ++> Sym(name="type_annotation");
    acc_body ++> block();
    acc_body ++> Lit(value=";");

    # enum ::= decorators "enum" access_tag name opt(base) ( "{" members opt(",") "}" | ";" )
    # base class: either `: Base` or `(Base, ...)` (jac.spec).
    en = g ++> Rule(name="enum") ++> Seq();
    en ++> [decorators(), Lit(value="enum"), access_tag()];
    en ++> Field(name="name") ++> name_ref();
    en_base_opt = en ++> Choice();
    en_body = en ++> Choice();
    en_base = en_base_opt ++> Choice();
    en_base_opt ++> Blank();
    en_base ++> Seq() ++> [Lit(value=":"), Sym(name="expression")];
    en_base_paren = en_base ++> Seq();
    en_base_paren ++> Lit(value="(");
    en_base_paren ++> Choice() ++> [comma_sep1(Sym(name="expression")), Blank()];
    en_base_paren ++> Lit(value=")");
    en_block = en_body ++> Seq();
    en_body ++> Lit(value=";");
    en_block ++> Lit(value="{");
    en_items = en_block ++> Rep() ++> Choice();
    en_block ++> Lit(value="}");
    en_member = en_items ++> Seq();
    en_member ++> Sym(name="enum_member");
    en_member ++> Choice() ++> [Lit(value=","), Blank()];
    en_items ++> [Sym(name="pyinline"), Sym(name="module_code")];

    enm = g ++> Rule(name="enum_member") ++> Seq();
    enm ++> name_ref();
    enm_type_opt = enm ++> Choice();
    enm_type_opt ++> Seq() ++> [Lit(value=":"), Sym(name="type_annotation")];
    enm_type_opt ++> Blank();
    enm_val_opt = enm ++> Choice();
    enm_val_opt ++> Seq() ++> [Lit(value="="), Sym(name="expression")];
    enm_val_opt ++> Blank();

    test_s = g ++> Rule(name="test") ++> Seq();
    test_s ++> [decorators(), Lit(value="test")];
    test_s ++> Choice() ++> [Sym(name="string"), Blank()];
    test_s ++> block();

    # global_var ::= "glob" access_tag comma_sep1(name opt(":" type) opt(rep1("=" expr))) ";"
    gv_item = Seq();
    gv_item ++> Field(name="name") ++> name_ref();
    gv_type_opt = gv_item ++> Choice();
    gv_vals_opt = gv_item ++> Choice();
    gv_type_opt ++> Seq() ++> [Lit(value=":"), Sym(name="type_annotation")];
    gv_type_opt ++> Blank();
    gv_vals = gv_vals_opt ++> Rep1();
    gv_vals_opt ++> Blank();
    gv_vals ++> Seq() ++> [Lit(value="="), Sym(name="expression")];
    gv = g ++> Rule(name="global_var") ++> Seq();
    gv ++> Choice() ++> [Lit(value="glob"), Lit(value="comptime")];
    gv ++> [access_tag(), comma_sep1(gv_item), Lit(value=";")];

    # The impl target is a dotted name PATH (`Class.method`, `Walker.entry`,
    # `Obj.init`), NOT a general expression -- using `expression` made
    # `impl X.f(params)` greedily parse as a call_expression, so the func
    # signature's `(` collided and every signature-bearing impl failed.
    impl_s = g ++> Rule(name="impl") ++> Seq();
    impl_s ++> [decorators(), Lit(value="impl")];
    impl_s ++> Field(name="target") ++> Sym(name="impl_target");
    impl_sig_opt = impl_s ++> Choice();
    impl_body = impl_s ++> Choice();
    impl_sig_opt ++> Choice() ++> [Sym(name="event_clause"), Sym(name="func_signature")];
    impl_sig_opt ++> Blank();
    impl_body ++> block();
    # Enum member values: `impl Color { RED = 1, GREEN = 2 }`.
    impl_enum = impl_body ++> Seq();
    impl_enum ++> Lit(value="{");
    impl_enum ++> comma_sep1(Sym(name="enum_member"));
    impl_enum ++> Choice() ++> [Lit(value=","), Blank()];
    impl_enum ++> Lit(value="}");
    impl_body ++> Seq() ++> [Lit(value="by"), Sym(name="expression"), Lit(value=";")];
    impl_body ++> Lit(value=";");

    it = g ++> Rule(name="impl_target") ++> Prec(kind="PREC_LEFT", level=1);
    it_s = it ++> Seq();
    it_s ++> Sym(name="impl_target_name");
    it_rest = it_s ++> Rep();
    it_rest ++> Seq() ++> [Lit(value="."), Sym(name="impl_target_name")];

    # impl_target_name (jac.spec): NAME/KWESC plus a few contextual keywords
    # that name abilities/ctors. Keyword extraction (word: identifier) keeps
    # these usable as ordinary identifiers elsewhere.
    itn = g ++> Rule(name="impl_target_name") ++> Choice();
    itn ++> [name_ref(),
             Lit(value="init"), Lit(value="postinit"), Lit(value="entry"), Lit(value="exit"), Lit(value="default"),
             Lit(value="getter"), Lit(value="setter"), Lit(value="deleter"), Lit(value="return")];

    ta = g ++> Rule(name="type_alias") ++> Seq();
    ta ++> [Lit(value="type"), access_tag()];
    ta ++> Field(name="name") ++> name_ref();
    ta ++> Choice() ++> [Sym(name="type_params"), Blank()];
    ta ++> Choice() ++> [Lit(value="="), Lit(value=":=")];
    ta ++> [Sym(name="type_annotation"), Lit(value=";")];

    tp_item = Seq();
    tp_item ++> Choice() ++> [Lit(value="comptime"), Blank()];
    tp_item ++> name_ref();
    tp_bound_opt = tp_item ++> Choice();
    tp_def_opt = tp_item ++> Choice();
    tp_bound_opt ++> Seq() ++> [Lit(value=":"), Sym(name="expression")];
    tp_bound_opt ++> Blank();
    tp_def_opt ++> Seq() ++> [Lit(value="="), Sym(name="expression")];
    tp_def_opt ++> Blank();
    tp = g ++> Rule(name="type_params") ++> Seq();
    tp ++> [Lit(value="["), comma_sep1(tp_item), Lit(value="]")];

    sd = g ++> Rule(name="sem_def") ++> Prec(kind="PREC_RIGHT", level=1);
    sem_s = sd ++> Seq();
    sem_s ++> [Lit(value="sem"), Sym(name="impl_target")];
    sem_s ++> Choice() ++> [Lit(value="="), Lit(value="is")];
    sem_s ++> Rep1() ++> Sym(name="string");
    sem_s ++> Choice() ++> [Lit(value=";"), Blank()];
}

# ===========================================================================
# Imports & module structure
# ===========================================================================

def build_imports(g: Grammar) -> None {
    # prec.right so the optional trailing `;` after the `{ ... }` items form is
    # shifted into THIS statement rather than left dangling (a benign
    # shift/reduce on the optional terminator).
    ist = g ++> Rule(name="import_statement") ++> Prec(kind="PREC_RIGHT", level=1);
    ist_s = ist ++> Seq();
    ist_s ++> Choice() ++> [Lit(value="comptime"), Blank()];
    ist_s ++> Choice() ++> [Lit(value="import"), Lit(value="include")];
    ist_s ++> Choice() ++> [Lit(value="type"), Blank()];
    ist_from_opt = ist_s ++> Choice();
    ist_body = ist_s ++> Choice();
    ist_from_opt ++> Seq() ++> [Lit(value="from"), Sym(name="import_path")];
    ist_from_opt ++> Blank();
    # The `{ ... }` items form ends in a block, so (like every other
    # block-bodied construct in Jac) it self-terminates and the trailing
    # `;` is optional -- real Jac omits it after `import from x { ... }`.
    ist_items = ist_body ++> Seq();
    ist_path = ist_body ++> Seq();
    ist_items ++> Sym(name="import_items");
    ist_items ++> Choice() ++> [Lit(value=";"), Blank()];
    ist_module = Seq();
    ist_module ++> Sym(name="import_path");
    ist_path_as = ist_module ++> Choice();
    ist_path_as ++> Seq() ++> [Lit(value="as"), name_ref()];
    ist_path_as ++> Blank();
    ist_path ++> comma_sep1(ist_module);
    ist_path ++> Lit(value=";");

    # precl(2) so extending the path (`a` + `.b`) binds TIGHTER than reducing
    # the enclosing `import_path` relative branch (precr 1) -- otherwise a
    # `...pkg.sub` path reduces after the first segment and orphans `.sub`.
    dn = g ++> Rule(name="dotted_name") ++> Choice();
    dn ++> name_ref();
    dn_rec = dn ++> Prec(kind="PREC_LEFT", level=2);
    dn_rec ++> Seq() ++> [Sym(name="dotted_name"), Lit(value="."), name_ref()];

    # Leading relative-import dots: `.`, `..`, `...` (and longer runs).
    # Explicit left-recursion + prec.left resolves the dot shift/reduce without
    # a GLR dynamic conflict. The dots only ever precede the path (never follow
    # a NAME), so they never clash with `dotted_name`'s own `.` separators.
    rp = g ++> Rule(name="relative_prefix") ++> Choice();
    rp ++> Choice() ++> [Lit(value="."), Lit(value="...")];
    rp_rec = rp ++> Prec(kind="PREC_LEFT", level=1);
    rp_rec_s = rp_rec ++> Seq();
    rp_rec_s ++> Sym(name="relative_prefix");
    rp_rec_s ++> Choice() ++> [Lit(value="."), Lit(value="...")];

    ip = g ++> Rule(name="import_path") ++> Choice();
    ip ++> [Sym(name="string"), Sym(name="dotted_name")];
    ip_rel = ip ++> Prec(kind="PREC_RIGHT", level=1);
    ip_rel_s = ip_rel ++> Seq();
    ip_rel_s ++> Sym(name="relative_prefix");
    ip_tail_opt = ip_rel_s ++> Choice();
    ip_tail_opt ++> Choice() ++> [Sym(name="string"), Sym(name="dotted_name")];
    ip_tail_opt ++> Blank();

    ii_item = Seq();
    ii_item ++> Choice() ++> [Lit(value="*"), Lit(value="default"), name_ref()];
    ii_as_opt = ii_item ++> Choice();
    ii_as_opt ++> Seq() ++> [Lit(value="as"), name_ref()];
    ii_as_opt ++> Blank();
    ii = g ++> Rule(name="import_items") ++> Seq();
    ii ++> Lit(value="{");
    ii_body = ii ++> Choice();
    ii ++> Lit(value="}");
    ii_names = ii_body ++> Seq();
    ii_names ++> comma_sep1(ii_item);
    ii_names ++> Choice() ++> [Lit(value=","), Blank()];
    # Declaration block, e.g. extern bindings: `import from c { def f() -> int; }`.
    ii_body ++> Rep1() ++> Choice() ++> [Sym(name="element"), Sym(name="has_statement")];
    ii_body ++> Blank();

    mod = g ++> Rule(name="module_code") ++> Seq();
    mod ++> Lit(value="with");
    mod_ee_opt = mod ++> Choice();
    mod_named_opt = mod ++> Choice();
    mod ++> block();
    mod_ee_opt ++> Choice() ++> [Lit(value="entry"), Lit(value="exit")];
    mod_ee_opt ++> Blank();
    mod_named_opt ++> Seq() ++> [Lit(value=":"), name_ref()];
    mod_named_opt ++> Blank();

    # Import wiring: `impl import pkg { edge E: a.* --> b.*; src --> dst { names } }`.
    imi = g ++> Rule(name="impl_import") ++> Seq();
    imi ++> [Lit(value="impl"), Lit(value="import")];
    imi_path_opt = imi ++> Choice();
    imi ++> Lit(value="{");
    imi ++> Rep() ++> Choice() ++> [Sym(name="import_rule"), Sym(name="import_wire")];
    imi ++> Lit(value="}");
    imi_path = imi_path_opt ++> Seq();
    imi_path_opt ++> Blank();
    imi_path ++> Field(name="path") ++> Choice() ++> [Sym(name="string"), Sym(name="dotted_name")];
    imi_as_opt = imi_path ++> Choice();
    imi_as_opt ++> Seq() ++> [Lit(value="as"), name_ref()];
    imi_as_opt ++> Blank();

    mpat = g ++> Rule(name="module_pattern") ++> Choice();
    mpat ++> [Lit(value="any"), Lit(value="*"), Sym(name="string"), Sym(name="dotted_name")];
    mpat ++> Seq() ++> [Sym(name="dotted_name"), Lit(value="."), Lit(value="*")];

    irule = g ++> Rule(name="import_rule") ++> Seq();
    irule ++> Lit(value="edge");
    irule ++> Field(name="name") ++> name_ref();
    irule ++> Lit(value=":");
    irule ++> Field(name="source") ++> Sym(name="module_pattern_list");
    irule ++> Lit(value="-->");
    irule ++> Field(name="target") ++> Sym(name="module_pattern_list");
    irule ++> Choice() ++> [Sym(name="wire_payload"), Lit(value=";")];

    iwire = g ++> Rule(name="import_wire") ++> Seq();
    iwire ++> Choice() ++> [Lit(value="comptime"), Blank()];
    iwire ++> Choice() ++> [Lit(value="include"), Lit(value="type"), Blank()];
    iwire ++> Field(name="source") ++> Sym(name="module_pattern_list");
    iwire ++> Lit(value="-->");
    iwire ++> Field(name="target") ++> Sym(name="module_pattern_list");
    iwire ++> Choice() ++> [Sym(name="wire_payload"), Lit(value=";")];

    mpl = g ++> Rule(name="module_pattern_list") ++> Seq();
    mpl ++> Sym(name="module_pattern");
    mpl ++> Rep() ++> Seq() ++> [Lit(value="|"), Sym(name="module_pattern")];

    wp_item = Seq();
    wp_item ++> Choice() ++> [Lit(value="*"), name_ref()];
    wp_as_opt = wp_item ++> Choice();
    wp_as_opt ++> Seq() ++> [Lit(value="as"), name_ref()];
    wp_as_opt ++> Blank();
    wp = g ++> Rule(name="wire_payload") ++> Seq();
    wp ++> Lit(value="{");
    wp ++> comma_sep(wp_item);
    wp ++> Choice() ++> [Lit(value=","), Blank()];
    wp ++> Lit(value="}");

    elem = g ++> Rule(name="element") ++> Choice();
    elem ++> [
        Sym(name="import_statement"),
        Sym(name="archetype"),
        Sym(name="ability"),
        Sym(name="enum"),
        Sym(name="test"),
        Sym(name="global_var"),
        Sym(name="impl"),
        Sym(name="sem_def"),
        Sym(name="type_alias"),
        Sym(name="module_code"),
        Sym(name="impl_import"),
        # Module-level `comptime if` / `comptime for` / `comptime assert`.
        Sym(name="if_statement"),
        Sym(name="for_statement"),
        Sym(name="assert_statement"),
        Sym(name="pyinline"),
        Sym(name="string"),
        Lit(value=";")
    ];
}

def build -> Grammar {
    g = Grammar(name="jac");
    g ++> Rule(name="source_file") ++> Rep() ++> Sym(name="element");
    build_imports(g);
    build_decls(g);
    build_stmts(g);
    build_patterns(g);
    build_expr(g);
    build_collections(g);
    build_edges(g);
    build_jsx(g);
    build_tokens(g);
    return g;
}

with entry {
    g = build();
    out = {
        "name": g.name,
        "word": "identifier",
        "extras": [emit(Pat(value="\\s")), emit(Sym(name="comment"))],
        "conflicts": [
            # Comprehension element vs. for-clause target: in `[<e> for <t> in ...]`
            # both `<e>` and the comma-separated `<t>` are expression-like, so
            # GLR must keep both interpretations until the `for`/`in` resolves it.
            ["expression", "for_in_clause"],
            # `<Foo.Bar>` (JSX member-tag name) vs `x < Foo.Bar` (less-than on a
            # dotted name): the dotted continuation is ambiguous, so GLR keeps
            # both the jsx_name and name_ref reads alive.
            ["jsx_name", "_name_ref"],
            # `{...expr}` JSX spread vs the `...` ellipsis atom starting an
            # expression -- only the spread is valid for `{...props}`, GLR drops
            # the other.
            ["jsx_attribute", "ellipsis"],
            # for-statement target (a primary-expr list) vs an expression: the
            # `for <t1, t2> in` target overlaps an expression list until `in`.
            ["expression", "for_statement"],
            # `{<a/> if c else <b/>}`: a JSX child block may open with a ternary, not a statement.
            ["jsx_statement", "_atom"],
            # `impl Color { RED = 1, ... }` vs a code block: decided at `,` or `;`.
            ["enum_member", "_atom"]
        ],
        # External tokens provided by src/scanner.c (hand-written C). Order MUST
        # match the TokenType enum in scanner.c.
        "externals": [
            emit(Sym(name="pyinline")), emit(Sym(name="jsx_text")),
            emit(Sym(name="fstring_start")), emit(Sym(name="fstring_content")),
            emit(Sym(name="fstring_end"))
        ],
        "inline": [],
        "supertypes": [],
        "rules": g.rules_json()
    };
    here = os.path.dirname(os.path.abspath(__file__));
    dest = os.path.join(here, "src", "grammar.json");
    with open(dest, "w") as f {
        f.write(json.dumps(out, indent=2) + "\n");
    }
    print(f"wrote {dest}");
}
