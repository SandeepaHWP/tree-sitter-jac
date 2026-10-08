"""Measure tree-sitter-jac parse error-density across a corpus of .jac files.

Parses every (or a sampled subset of) .jac file under a corpus directory with
the locally generated parser and reports the pass rate -- a file "passes" when
its parse tree contains no ERROR or MISSING nodes. Breaks the result down by
Jac file flavor (plain / .impl / .na / .cl / .test / .sv) so regressions in any
one surface area are visible, and tracks error-density per release.

Usage:
    jac run scripts/error-density.jac <corpus-dir> [--sample N] [--seed S] [--triage]

    --sample N   parse a random N-file subset (default: all files)
    --triage     also print the most common first-error tokens and line
                 skeletons, to prioritise the next grammar fix
"""

import argparse;
import random;
import re;
import shutil;
import subprocess;
import sys;
import from collections { Counter }
import from pathlib { Path }

glob ROOT: Path = Path(__file__).resolve().parent.parent;
glob LOCAL_TS: Path = ROOT / "node_modules" / ".bin" / "tree-sitter";
glob TS: str | None = str(LOCAL_TS) if LOCAL_TS.exists() else shutil.which("tree-sitter");

glob FLAVORS: list[str] = [".impl.jac", ".cl.jac", ".na.jac", ".test.jac", ".sv.jac"];


def flavor(path: Path) -> str {
    for f in FLAVORS {
        if path.name.endswith(f) {
            return f;
        }
    }
    return ".jac";
}


"""Return (row, col) of the first ERROR/MISSING node, or None."""
def first_error(tree: str) -> any {
    m = re.search(r"\((?:ERROR|MISSING)[^\[]*\[(\d+), (\d+)\]", tree);
    return (int(m.group(1)), int(m.group(2))) if m else None;
}


def skeleton(line: str) -> str {
    norm = re.sub(r'"[^"]*"|\'[^\']*\'', '"S"', line.strip());
    norm = re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\b", "N", norm);
    return re.sub(r"\s+", " ", norm)[:60];
}


def main() -> int {
    ap = argparse.ArgumentParser();
    ap.add_argument("corpus");
    ap.add_argument("--sample", type=int, `default=0);
    ap.add_argument("--seed", type=int, `default=7);
    ap.add_argument("--triage", action="store_true");
    args = ap.parse_args();

    if TS is None {
        sys.exit("tree-sitter CLI not found; run `npm install tree-sitter-cli@0.22.6`");
    }

    files = [p for p in Path(args.corpus).rglob("*.jac") if p.stat().st_size > 0];
    if args.sample and args.sample < len(files) {
        random.seed(args.seed);
        files = random.sample(files, args.sample);
    }

    by_flavor = {};
    (tokens, skels) = (Counter(), Counter());
    for p in files {
        out = subprocess.run([TS, "parse", str(p)], capture_output=True, text=True, cwd=ROOT);
        ok = out.returncode == 0 and "(ERROR" not in out.stdout and "MISSING" not in out.stdout;
        (tot, ps) = by_flavor.setdefault(flavor(p), [0, 0]);
        by_flavor[flavor(p)] = [tot + 1, ps + (1 if ok else 0)];
        if not ok and args.triage {
            pos = first_error(out.stdout);
            if pos {
                src = p.read_text(errors="replace").splitlines();
                if pos[0] < len(src) {
                    line = src[pos[0]];
                    seg = line[pos[1]:].lstrip();
                    tm = re.match(r"[^\s()\[\]{},;:]+|.", seg);
                    tokens[(tm.group(0) if tm else "?")] += 1;
                    skels[skeleton(line)] += 1;
                }
            }
        }
    }

    (gt, gp) = (0, 0);
    print(f"{'flavor':10} {'total':>6} {'pass':>6} {'rate':>7}");
    for fl in sorted(by_flavor) {
        (tot, ps) = by_flavor[fl];
        gt += tot;
        gp += ps;
        print(f"{fl:10} {tot:6d} {ps:6d} {100*ps/tot:6.1f}%");
    }
    print(f"{'ALL':10} {gt:6d} {gp:6d} {100*gp/gt:6.1f}%" if gt else "no files");

    if args.triage {
        print("\ntop first-error tokens:");
        for (t, c) in tokens.most_common(15) {
            print(f"  {c:4d}  {t!r}");
        }
        print("\ntop first-error line skeletons:");
        for (s, c) in skels.most_common(20) {
            print(f"  {c:4d}  {s}");
        }
    }
    return 0;
}


with entry:__main__ {
    sys.exit(main());
}
