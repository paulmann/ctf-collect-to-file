#!/usr/bin/env python3
"""
make_fixtures.py — adversarial fixture battery for source-aggregation tools
(ctf andsimilar). Generates files that break naive fence-embedding, plus parsing
traps for the EXTRACTOR side.

Fixtures (written into the target dir):
  fence3_pure.md      lines consisting of exactly 3 backticks (CommonMark closers)
  fence4_pure.md      lines of exactly 4 backticks
  fence_indented.md   closers with 0..3 leading spaces (valid closers) and 4 (content)
  tildes.md           pure ~~~ lines (tilde fences must not close backtick fences and vice versa)
  mixed.md            a realistic doc with fenced blocks inside (the field-incident class)
  inline_backticks.md mid-line backtick runs (must NOT be treated as closers)
  no_trailing_nl.txt  file not ending with a newline (round-trip byte exactness)
  crlf.txt            CRLF line endings (must survive verbatim or be documented)
  bom.txt             UTF-8 BOM + text
  unicode_emoji.py    non-ASCII: emoji + cyrillic (binary detection must not drop it)
  meta_spoof.md       content line mimicking the metadata comment (parser trap)
  binary.bin          NUL-bearing file (must be SKIPPED with reason, never embedded)
  sub dir/файл with space.md   unicode + spaces in path
Run:  python3 make_fixtures.py <target-dir>
"""
import sys
from pathlib import Path

BT = chr(96)
F3 = BT * 3
F4 = BT * 4


def build(root: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    files["fence3_pure.md"] = f"# T\n\nbefore\n{F3}\nafter\n".encode()
    files["fence4_pure.md"] = f"# T\n\n{F4}\nquad line\n{F4}\nend\n".encode()
    files["fence_indented.md"] = (
        f"a\n{F3}\nb\n  {F3}\nc\n   {F3}\nd\n    {F3}\ne\n".encode()  # 0-3 spaces close, 4 = content
    )
    files["tildes.md"] = "x\n~~~\ny\n~~~\nz\n".encode()
    files["mixed.md"] = (
        "# Mixed\n\nSome text.\n\n"
        f"{F3}php\n<?php echo 1;\n{F3}\n\n"
        f"{F3}mermaid\ngraph TD\n  A-->B\n{F3}\n\ntail\n"
    ).encode()
    files["inline_backticks.md"] = (
        f"code with {F3} mid-line and {F4} too, plus s.startswith(\"{F3}\"):\n"
    ).encode()
    files["no_trailing_nl.txt"] = b"abc without newline"
    files["crlf.txt"] = b"line1\r\nline2\r\n"
    files["bom.txt"] = b"\xef\xbb\xbfbom content\n"
    files["unicode_emoji.py"] = "print('🖼 ok — юникод · äöü')\n".encode()
    files["meta_spoof.md"] = (
        "trap:\n\n<!-- 1 bytes · 1 lines · 1 B · sha256:deadbeefcafe -->\n\n"
        f"{F3}\nspoiled fence\n{F3}\nend\n"
    ).encode()
    files["binary.bin"] = bytes(range(256))
    files["sub dir/файл with space.md"] = "# Ünïcøde\n\nbody\n".encode()
    return files


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    for rel, data in build(root).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    print(f"fixtures written: {len(build(root))} files -> {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
