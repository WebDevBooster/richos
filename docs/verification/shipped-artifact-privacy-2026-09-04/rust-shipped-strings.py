#!/usr/bin/env python3
"""Print the Rust code that can actually reach a RELEASE binary.

A grep over `.rs` files answers the wrong question. Comments are discarded by the
compiler and `#[cfg(test)]` items are never built in a release profile, so a name found
in either of those places does NOT ship. This filter removes both and prints what is
left, so a category sweep over its output is a statement about the ARTIFACT rather than
about the repository.

TWO VIEWS OF THE SAME BYTES, and the distinction is the whole reason this is a script
rather than a `sed`. Brace matching runs over a copy in which every string and char
literal has been blanked, because `crates/richos-core/src/correction.rs` contains the
literal `"\\n#[cfg(test)]"` and several files contain a lone `"{"` — counting braces
inside literals unbalances the scan and silently leaves a test module in the output.
Grepping runs over a copy in which the literals are intact, because a literal is exactly
the thing that ships. Getting these the wrong way round was a real defect here: the first
version of this script counted braces through literals, its `#[cfg(test)]` scan never
resolved, and it reported forty-plus test-only hits as shipped.

Conservative in the direction that matters: an item whose braces do not resolve stays IN
the output, so the sweep over-reports rather than under-reports.

Usage: rust-shipped-strings.py FILE...   (prints "path:line: text" for surviving lines)
Self-test: rust-shipped-strings.py --self-test
"""
import sys


def scan(src):
    """Return (kept, code) — comments blanked in both, literals blanked in `code` only.

    Offsets and line breaks are preserved in both, so an index into one is an index
    into the other and into the original.
    """
    kept, code = [], []
    i, n = 0, len(src)

    def emit(text, blank_in_code):
        kept.append(text)
        code.append("".join("\n" if c == "\n" else " " for c in text) if blank_in_code else text)

    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = i
            while j < n and src[j] != "\n":
                j += 1
            emit(" " * (j - i), False)
            i = j
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            emit("".join("\n" if ch == "\n" else " " for ch in src[i:j]), False)
            i = j
            continue
        if c == '"':
            hashes, k = 0, i - 1
            while k >= 0 and src[k] == "#":
                hashes += 1
                k -= 1
            if hashes and k >= 0 and src[k] == "r":
                term = '"' + "#" * hashes
                end = src.find(term, i + 1)
                end = n if end < 0 else end + len(term)
            else:
                k = i + 1
                while k < n:
                    if src[k] == "\\":
                        k += 2
                        continue
                    if src[k] == '"':
                        k += 1
                        break
                    k += 1
                end = k
            emit(src[i:end], True)
            i = end
            continue
        if c == "'" and i + 2 < n:
            # A char literal, not a lifetime: 'x' or '\n' or '\u{7b}'.
            end = None
            if src[i + 1] == "\\":
                k = i + 2
                while k < n and src[k] != "'":
                    k += 1
                if k < n and k - i <= 12:
                    end = k + 1
            elif src[i + 2] == "'":
                end = i + 3
            if end:
                emit(src[i:end], True)
                i = end
                continue
        emit(c, False)
        i += 1

    return "".join(kept), "".join(code)


def drop_cfg_test(kept, code):
    """Blank out every `#[cfg(test)] ... { ... }` item in `kept`, keeping offsets."""
    out = list(kept)
    idx = 0
    while True:
        idx = code.find("#[cfg(test)]", idx)
        if idx < 0:
            break
        brace = code.find("{", idx)
        if brace < 0:
            break
        depth, j = 0, brace
        while j < len(code):
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if depth != 0:  # unbalanced: keep it in, so the sweep over-reports
            idx += 1
            continue
        for k in range(idx, j + 1):
            if out[k] != "\n":
                out[k] = " "
        idx = j + 1
    return "".join(out)


def shipped(src):
    kept, code = scan(src)
    return drop_cfg_test(kept, code)


SELF_TEST = r'''
const SHIPPED: &str = "loro-root";
// a comment naming acme-corp
/* block naming acme-corp */
fn brace_literal() -> &'static str { "{" }
fn char_literal() -> char { '{' }

#[cfg(test)]
mod tests {
    const NEEDLE: &str = "\n#[cfg(test)]";
    #[test]
    fn t() { assert_eq!("acme-corp", "acme-corp"); }
}
'''


def self_test():
    out = shipped(SELF_TEST)
    checks = [
        ("runtime literal survives", "loro-root" in out),
        ("line comment dropped", out.count("acme-corp") == 0),
        ("cfg(test) module dropped", "NEEDLE" not in out and "assert_eq" not in out),
        ("brace-in-literal did not unbalance the scan", "fn brace_literal" in out),
        ("line count preserved", out.count("\n") == SELF_TEST.count("\n")),
    ]
    bad = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    return 1 if bad else 0


def main(argv):
    if argv and argv[0] == "--self-test":
        return self_test()
    for path in argv:
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        for lineno, line in enumerate(shipped(src).split("\n"), 1):
            if line.strip():
                print(f"{path}:{lineno}: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
