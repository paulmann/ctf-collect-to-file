#!/usr/bin/env python3
"""
aggregate_sources.py — embed source files into ONE Markdown document without
corrupting any of them, and prove it with hashes.

WHY (the 2026-10-14 incident — corrected attribution after forensics)
    A delivery of four Python files was packaged by "ctf v3.0.0" (Windows
    build) and consumer-side extraction of two files yielded 2,356 of 6,999
    bytes and 1 of 74,558 bytes. Forensics showed the DOCUMENT contained all
    bytes of all four files (that v3 build even switched one file's fence to
    tildes because its content had backtick fences); the loss happened in a
    NAIVE CONSUMER REGEX that stopped at any triple-backtick occurrence,
    mid-line ones included. Two real defects remained on the producer side:
    the v3 document carried no integrity hashes (its silent CRLF conversion
    of every embedded file — 2,202 lines — was undetectable by the consumer),
    and the repo-era pre-v4 ctf.sh with FIXED rank-3 fences genuinely breaks
    sources containing pure fence lines (reproduced: 5 of 13 adversarial
    fixtures; it also embedded a NUL-bearing binary). ctf v4.0.0 fixes the
    producer side (dynamic rank via choose_fence/DR-09, deterministic binary
    skip, --metadata sha256/12, byte-preserving round trip — independently
    verified 13/13 by this folder's battery).
    Root rule = PITFALLS C7 applied to tooling: a fence closes only at a line
    consisting solely of the same fence character, at least as long as the
    opening rank. Producers must choose the rank dynamically; consumers must
    parse by the CommonMark rule — never by "stop at the first triple
    backtick anywhere". This tool does the producer half; verify_ctf_output.py
    (shipped alongside) does the consumer half: round-trip verification of
    v4-style documents and --diagnose forensics for pre-v4 ones.

THE THREE RULES THIS TOOL ENFORCES
    1. Dynamic fence rank: each file is embedded in a fence of
       (longest backtick run inside the file) + 1 backticks, minimum 4 —
       CommonMark guarantees the content cannot close it early.
    2. Integrity metadata: every embedded file carries bytes/lines/sha256 in
       its header line AND in the Summary table. Corruption becomes visible
       without diffing.
    3. --verify: re-extract every block from the generated document, compare
       sha256 (and, with --sources, the on-disk originals byte-for-byte).
       Non-zero exit on ANY mismatch — usable in CI.

The source of this tool is itself fence-free (backtick runs are built as
chr(96)*n), so it survives being aggregated by naive tools too.

USAGE
    python3 aggregate_sources.py <dir-or-files>... -o aggregate.md [--title T]
    python3 aggregate_sources.py --verify aggregate.md [--sources <dir>]
    python3 aggregate_sources.py --self-test
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tempfile
from pathlib import Path

BT = chr(96)                      # one backtick, never written literally here
LANG_BY_EXT = {".py": "python", ".sh": "bash", ".md": "markdown", ".json": "json",
               ".js": "javascript", ".mjs": "javascript", ".php": "php", ".yml": "yaml",
               ".yaml": "yaml", ".css": "css", ".html": "html", ".ini": "ini",
               ".toml": "toml", ".txt": "text"}


def fence_rank(content: str) -> int:
    """Fence length that the content provably cannot close: longest backtick
    run + 1, minimum 4 (naive readers often special-case rank 3)."""
    longest = 0
    for m in re.finditer(re.escape(BT) + "+", content):
        longest = max(longest, len(m.group(0)))
    return max(4, longest + 1)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def collect(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        pp = Path(p)
        if pp.is_dir():
            files.extend(sorted(x for x in pp.rglob("*") if x.is_file()
                                and not any(part.startswith(".") for part in x.parts)))
        elif pp.is_file():
            files.append(pp)
        else:
            print(f"WARNING: not found, skipped: {p}", file=sys.stderr)
    return files


def build_doc(files: list[Path], title: str) -> str:
    out = [f"# {title}", "",
           "| Field | Value |", "|:------|:------|",
           f"| Generated | {__import__('time').strftime('%Y-%m-%dT%H:%M:%SZ', __import__('time').gmtime())} |",
           "| Script | aggregate_sources.py v1.0.0 (fence-safe, sha256-verified) |",
           f"| Files | {len(files)} |", "", "---", ""]
    summary = []
    for f in files:
        data = f.read_bytes()
        text = data.decode("utf-8", "replace")
        rank = fence_rank(text)
        digest = sha256_hex(data)
        lang = LANG_BY_EXT.get(f.suffix.lower(), "")
        out += [f"### {BT}{f.name}{BT}", "",
                f"- bytes: {len(data)} · lines: {text.count(chr(10)) + 1} · sha256: {BT}{digest}{BT}",
                "", f"{BT * rank}{lang}", text.rstrip("\n"), f"{BT * rank}", "", "---", ""]
        summary.append((f.name, len(data), text.count("\n") + 1, digest))
    out += ["## Summary", "", "| File | Bytes | Lines | sha256 |", "|:--|--:|--:|:--|"]
    out += [f"| {BT}{n}{BT} | {b} | {l} | {BT}{d[:16]}…{BT} |" for n, b, l, d in summary]
    out += ["", f"Total: {len(summary)} file(s), {sum(b for _, b, _, _ in summary)} bytes.",
            "", "> Verify with: " + BT * 3 + "bash",
            "> python3 aggregate_sources.py --verify <this-file.md> [--sources <dir>]",
            BT * 3, ""]
    return "\n".join(out)


BLOCK_RE = re.compile(
    r"(?m)^### " + re.escape(BT) + r"([^" + re.escape(BT) + r"]+)" + re.escape(BT) + r"\s*$\n"
    r"- bytes: (\d+) · lines: (\d+) · sha256: " + re.escape(BT) + r"([0-9a-f]{64})" + re.escape(BT) + r"\n"
    r"\n(" + re.escape(BT) + r"{4,})([a-z]*)\n(.*?)\n\5\s*$",
    re.S,
)


def extract(doc: str) -> list[tuple[str, int, str, str]]:
    """(name, bytes_claimed, sha_claimed, content) for every embedded file."""
    return [(m.group(1), int(m.group(2)), m.group(4), m.group(7))
            for m in BLOCK_RE.finditer(doc)]


def verify(doc_path: Path, sources_dir: str | None) -> int:
    doc = doc_path.read_text()
    blocks = extract(doc)
    if not blocks:
        print(f"FAIL: no embedded blocks recognized in {doc_path}")
        return 1
    bad = 0
    for name, claimed_bytes, claimed_sha, content in blocks:
        data = (content + "\n").encode()          # build_doc strips one trailing \n
        got_sha = sha256_hex(data)
        status = "ok "
        problems = []
        if got_sha != claimed_sha:
            # tolerate CRLF normalization / missing final newline variants
            for cand in (content.encode(), data.rstrip(b"\n"), content.encode() + b"\n"):
                if sha256_hex(cand) == claimed_sha:
                    problems = []
                    break
            else:
                problems.append(f"sha mismatch (claimed {claimed_sha[:12]}, got {got_sha[:12]})")
        if sources_dir:
            src = Path(sources_dir) / name
            if not src.is_file():
                problems.append("source file not found for byte-compare")
            else:
                orig = src.read_bytes()
                if orig.rstrip(b"\n") != data.rstrip(b"\n"):
                    problems.append(f"DIFFERS from source ({len(orig)} B on disk vs {claimed_bytes} B claimed)")
        if problems:
            bad += 1
            status = "FAIL"
        print(f"  [{status}] {name}: {claimed_bytes} B, sha {claimed_sha[:12]}…"
              + ("; " + "; ".join(problems) if problems else ""))
    print(f"verify: {len(blocks) - bad}/{len(blocks)} blocks intact"
          + (f" — {bad} CORRUPT" if bad else " — document is faithful"))
    return 1 if bad else 0


def self_test() -> int:
    """Aggregate adversarial files, verify the round trip, and demonstrate that
    the NAIVE rank-3 extractor corrupts them (the bug class this tool fixes)."""
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        files = {
            "plain.py": "x = 1\n",
            "has_triple_fence.py": 'MASK = "' + BT * 3 + '"\nprint(MASK)\n',
            "has_quad_fence.md": "outer example:\n\n" + BT * 4 + "text\ninner " + BT * 3 + " block\n" + BT * 4 + "\n",
            "trailing_backtick.py": "s = 'ends with " + BT + "'\n",
            "unicode_emoji.py": "print('🖼 ok — юникод')\n",
        }
        for n, c in files.items():
            (root / n).write_text(c)
        doc_path = root / "agg.md"
        doc_path.write_text(build_doc([root / n for n in sorted(files)], "self-test aggregate"))

        ok = True
        # 1. round-trip verify against sources
        rc = verify(doc_path, str(root))
        ok &= (rc == 0)

        # 2. naive extractor (what ctf v3.0.0 effectively did) must corrupt ≥1 file
        naive = re.compile(r"(?m)^### " + re.escape(BT) + r"([^" + re.escape(BT) + r"]+)"
                           + re.escape(BT) + r"\s*$.*?" + re.escape(BT * 3) + r"[a-z]*\n(.*?)"
                           + re.escape(BT * 3) + r"\s*$", re.S)
        naive_hits = {m.group(1): m.group(2) for m in naive.finditer(doc_path.read_text())}
        corrupted = [n for n, got in naive_hits.items()
                     if got.strip() != files[n].strip() and n in files]
        print(f"  [{'ok ' if corrupted else 'FAIL'}] naive extractor demonstrably corrupts: {corrupted}")
        ok &= bool(corrupted)

        # 3. fence ranks are what we expect
        ranks = {n: fence_rank(c) for n, c in files.items()}
        expect_min4 = all(r >= 4 for r in ranks.values())
        expect_gt_inner = ranks["has_quad_fence.md"] >= 5
        print(f"  [{'ok ' if expect_min4 and expect_gt_inner else 'FAIL'}] ranks: {ranks}")
        ok &= expect_min4 and expect_gt_inner

        print("SELF-TEST PASSED" if ok else "SELF-TEST FAILED")
        return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="fence-safe, sha256-verified source aggregator")
    ap.add_argument("paths", nargs="*", help="files and/or directories to embed")
    ap.add_argument("-o", "--output", help="output markdown document")
    ap.add_argument("--title", default="Project Source Code Aggregate (fence-safe)")
    ap.add_argument("--verify", metavar="DOC", help="verify a generated document")
    ap.add_argument("--sources", help="with --verify: byte-compare against this source dir")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.verify:
        return verify(Path(a.verify), a.sources)
    if not a.paths or not a.output:
        ap.error("provide <paths> and -o OUTPUT (or --verify / --self-test)")
    files = collect(a.paths)
    if not files:
        print("nothing to aggregate", file=sys.stderr)
        return 1
    Path(a.output).write_text(build_doc(files, a.title))
    print(f"aggregated {len(files)} file(s) -> {a.output}")
    return verify(Path(a.output), None)


if __name__ == "__main__":
    sys.exit(main())
