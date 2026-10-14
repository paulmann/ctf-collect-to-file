#!/usr/bin/env python3
"""
verify_ctf_output.py — independent round-trip verifier for ctf (Collect To File)
Markdown aggregates, and a corruption DIAGNOSER for pre-v4 documents.

WHY IT EXISTS
    ctf v4.0.0 embeds files in dynamically-ranked fences and can stamp
    per-file sha256/12 metadata — but it ships no way to verify the produced
    document, and documents made by ctf v3 (fixed 3-backtick fences, no
    hashes) can be structurally broken while looking complete: every byte is
    present, yet any CommonMark-conformant parser recovers only the part
    before the first pure fence line inside a file. Field incident
    (2026-10-14): a 74,558-byte Python source whose markdown fixtures
    contained pure 3-backtick lines was embedded by v3 in a rank-3 block —
    unrecoverable by parsing, while the Summary cheerfully reported success.

WHAT IT DOES
    verify  (default)  parse a ctf v4 md document; for every section extract
                       the fenced block per CommonMark closing rules and
                       compare sha256 against (a) the metadata comment and
                       (b) with --sources DIR, the original files byte-for-byte
                       (tolerating: one added trailing newline for files
                       without one, CRLF transport normalization, budget
                       truncation markers). Checks the counter invariants
                       (Collected + Skipped = Candidates, sections = Collected).
    --diagnose         works on ANY md aggregate incl. metadata-less v3 docs:
                       simulates fence parsing section by section and reports
                       BROKEN-EMBED when non-whitespace content follows the
                       block's first valid closer inside the same section
                       (the v3 defect signature), plus a best-effort byte
                       recovery estimate.

EXIT CODES  0 = all verified / no broken blocks · 1 = integrity failures or
broken blocks found · 2 = usage error.

This tool is itself fence-free (backtick runs built via chr(96)) so it can be
aggregated by any tool, naive ones included.

USAGE
    python3 verify_ctf_output.py DOC.md [--sources DIR] [--json out.json]
    python3 verify_ctf_output.py OLD_AGGREGATE.md --diagnose
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

BT = chr(96)
TILDE = "~"

SECTION_RE = re.compile(r"^###\s+" + re.escape(BT) + r"?(.+?)" + re.escape(BT) + r"?\s*$")
META_RE = re.compile(
    r"^<!--\s*(\d+)\s*bytes\s*·\s*(\d+)\s*lines\s*·[^·]*·\s*sha256:([0-9a-f]{12,64})\s*-->$"
)
TRUNC_RE = re.compile(r"^<!--\s*truncated[^>]*-->$")
FENCE_OPEN_RE = re.compile(r"^ {0,3}(" + re.escape(BT) + r"{3,}|" + re.escape(TILDE) + r"{3,})([^" + re.escape(BT + TILDE) + r"\s]*)\s*$")


def is_closer(line: str, char: str, rank: int) -> bool:
    """CommonMark: a closing fence is a line of ONLY the same fence char,
    length >= opening rank, indented at most 3 spaces."""
    m = re.match(r"^ {0,3}(" + re.escape(char) + r"{3,})\s*$", line)
    return bool(m) and len(m.group(1)) >= rank


def split_lines(text: str) -> list[str]:
    return text.split("\n")


def parse_sections(lines: list[str]) -> list[dict]:
    """Section = from a '### name' heading to the next heading, FENCE-AWARE.

    Headings inside an open fenced block are content, not structure — a parser
    that ignores fence state misdiagnoses files whose source contains lines
    like '### Sub section' (caught by the field document: fix_toc.py embeds a
    markdown fixture inside a Python string). For pre-v4 BROKEN documents the
    fence state itself desynchronizes at the first early closer — which is
    exactly the defect signature this tool must surface, so the simulation
    follows CommonMark rules literally and lets the chips fall.
    """
    secs, cur = [], None
    fence_char, fence_rank = None, 0
    quoted_heading = re.compile(r"^###\s+" + re.escape(BT) + r"(.+?)" + re.escape(BT) + r"\s*$")
    for i, line in enumerate(lines):
        if fence_char is not None:
            if is_closer(line, fence_char, fence_rank):
                fence_char, fence_rank = None, 0
            elif quoted_heading.match(line.rstrip("\r")):
                # RESYNC: ctf always emits section headings with the name in
                # backticks; content headings are not backticked. Inside a
                # structurally broken (pre-v4) document the fence state
                # desyncs after the first early closer — a backticked heading
                # is the reliable anchor to restart from. The previous section
                # keeps whatever leaked lines were collected (its BROKEN
                # status is decided by extract_block).
                if cur:
                    cur["end"] = i
                    secs.append(cur)
                cur = {"name": quoted_heading.match(line.rstrip("\r")).group(1),
                       "start": i, "end": len(lines), "lines": []}
                fence_char, fence_rank = None, 0   # a real heading is never inside a fence
                continue
            if cur is not None:
                cur["lines"].append(line)
            continue
        m_open = FENCE_OPEN_RE.match(line)
        m_sec = SECTION_RE.match(line)
        is_h2 = line.startswith("## ") and not line.startswith("###")
        if m_sec or is_h2:
            if cur:
                cur["end"] = i
                secs.append(cur)
                cur = None
        if m_sec:
            cur = {"name": m_sec.group(1), "start": i, "end": len(lines), "lines": []}
        elif cur is not None:
            cur["lines"].append(line)
            if m_open:
                fence_char, fence_rank = m_open.group(1)[0], len(m_open.group(1))
    if cur:
        secs.append(cur)
    return secs


def extract_block(sec_lines: list[str]) -> dict:
    """Find the first fenced block in a section; return extraction details.

    result keys: found, char, rank, content (str|None), closed, trailing_after
    (non-whitespace lines after the closer within the section, fence lines and
    separators excluded), meta (bytes/lines/sha or None), truncated (bool).
    """
    meta = None
    truncated = any(TRUNC_RE.match(l) for l in sec_lines)
    for l in sec_lines:
        mm = META_RE.match(l.strip())
        if mm:
            meta = {"bytes": int(mm.group(1)), "lines": int(mm.group(2)), "sha": mm.group(3)}
            break
    open_i = None
    for i, l in enumerate(sec_lines):
        if FENCE_OPEN_RE.match(l):
            open_i = i
            break
    if open_i is None:
        return {"found": False, "meta": meta, "truncated": truncated}
    m = FENCE_OPEN_RE.match(sec_lines[open_i])
    fence, char, rank = m.group(1), m.group(1)[0], len(m.group(1))
    content, close_i = [], None
    for j in range(open_i + 1, len(sec_lines)):
        if is_closer(sec_lines[j], char, rank):
            close_i = j
            break
        content.append(sec_lines[j])
    trailing = []
    if close_i is not None:
        for l in sec_lines[close_i + 1:]:
            s = l.strip()
            if s in ("", "---") or TRUNC_RE.match(l):
                continue
            trailing.append(l)
    return {"found": True, "char": char, "rank": rank,
            "content": "\n".join(content), "closed": close_i is not None,
            "trailing_after": trailing, "meta": meta, "truncated": truncated}


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def candidates(content: str) -> list[tuple[str, bytes]]:
    """Byte variants a faithful extractor may legitimately produce."""
    out = []
    raw = content.encode("utf-8", "surrogateescape")
    out.append(("exact", raw))
    out.append(("minus-one-trailing-nl", raw[:-1] if raw.endswith(b"\n") else raw))
    if not raw.endswith(b"\n"):
        out.append(("plus-trailing-nl", raw + b"\n"))
    if b"\r\n" in raw:
        lf = raw.replace(b"\r\n", b"\n")
        out.append(("crlf-to-lf", lf))
        out.append(("crlf-to-lf-minus-nl", lf[:-1] if lf.endswith(b"\n") else lf))
    dedup, seen = [], set()
    for tag, b in out:
        if sha(b) not in seen:
            seen.add(sha(b))
            dedup.append((tag, b))
    return dedup


def read_doc(doc_path: Path) -> str:
    """Read as BYTES then decode: text-mode universal-newline translation would
    silently convert CRLF to LF and break byte-exact verification of files
    with CRLF endings (caught by the crlf.txt fixture)."""
    return doc_path.read_bytes().decode("utf-8", "surrogateescape")


def verify(doc_path: Path, sources: Path | None, json_out: Path | None) -> int:
    text = read_doc(doc_path)
    lines = split_lines(text)
    sections = parse_sections(lines)
    results, failures = [], 0

    # counter invariants from header/summary tables
    def table_value(key: str) -> int | None:
        m = re.search(r"^\|\s*" + re.escape(key) + r"\s*\|\s*(\d+)\s*\|", text, re.M)
        return int(m.group(1)) if m else None

    cand, coll, skip = table_value("Candidates"), table_value("Collected"), table_value("Skipped")
    if None not in (cand, coll, skip):
        ok = (coll + skip == cand) and (coll == len(sections))
        results.append({"check": "counters", "ok": ok,
                        "detail": f"Candidates={cand} Collected={coll} Skipped={skip} sections={len(sections)}"})
        failures += 0 if ok else 1
    else:
        results.append({"check": "counters", "ok": None,
                        "detail": "counter tables not found (pre-v4 document?) — use --diagnose"})

    for sec in sections:
        name = sec["name"]
        ex = extract_block(sec["lines"])
        r = {"file": name, "ok": False, "detail": ""}
        if not ex["found"]:
            r["detail"] = "no fenced block in section (lang-style indent4/none not supported by this verifier)"
            results.append(r); failures += 1
            continue
        if not ex["closed"]:
            r["detail"] = f"block opened with rank-{ex['rank']} {ex['char']*0 or ''}fence never closed"
            results.append(r); failures += 1
            continue
        if ex["trailing_after"]:
            r["detail"] = ("BROKEN-EMBED: %d content line(s) after the block's first valid closer "
                           "(v3-style defect); first: %r" % (len(ex["trailing_after"]),
                                                             ex["trailing_after"][0][:60]))
            results.append(r); failures += 1
            continue
        cands = candidates(ex["content"])
        matched = None
        if ex["meta"]:
            for tag, b in cands:
                if sha(b).startswith(ex["meta"]["sha"][:12]):
                    matched = ("meta:" + tag, b)
                    break
            if matched is None and ex["truncated"]:
                matched = ("truncated-by-budget (hash mismatch expected)", None)
        if matched is None and sources:
            src = sources / name
            if src.is_file():
                orig = src.read_bytes()
                for tag, b in cands:
                    if b == orig:
                        matched = ("source:" + tag, b)
                        break
        if matched is None and not ex["meta"] and not sources:
            r["ok"] = None
            r["detail"] = (f"extracted {len(cands[0][1])} B (rank-{ex['rank']} fence) — no metadata and no "
                           f"--sources given; nothing to compare against")
            results.append(r)
            continue
        if matched is None:
            r["detail"] = ("HASH MISMATCH: metadata sha256:%s… but extracted variants are %s"
                           % (ex["meta"]["sha"][:12] if ex["meta"] else "-",
                              ", ".join(t for t, _ in cands)))
            results.append(r); failures += 1
            continue
        r["ok"] = True
        extra = ""
        if ex["meta"] and sources and (sources / name).is_file():
            orig = (sources / name).read_bytes()
            got = matched[1]
            extra = "" if got == orig else f" (note: matched via {matched[0]}; source bytes differ in trailing newline/CRLF only)"
        r["detail"] = f"verified via {matched[0]}{extra}"
        results.append(r)

    n_ok = sum(1 for r in results if r.get("ok") is True)
    n_bad = failures
    for r in results:
        flag = {True: "ok  ", False: "FAIL", None: "?   "}[r.get("ok")]
        print(f"  [{flag}] {r.get('file', r.get('check', '?'))}: {r['detail'][:150]}")
    print(f"verify: {n_ok} file(s) verified, {n_bad} problem(s), {len(sections)} section(s) total")
    if json_out:
        json_out.write_text(json.dumps({"document": str(doc_path), "results": results,
                                        "failures": n_bad}, indent=1, ensure_ascii=False))
    return 1 if n_bad else 0


def diagnose(doc_path: Path, json_out: Path | None) -> int:
    """Metadata-less forensics for pre-v4 aggregates: which embedded files are
    structurally broken (content after an early closer), which are intact."""
    text = read_doc(doc_path)
    sections = parse_sections(split_lines(text))
    broken, intact, noblock = [], [], []
    for sec in sections:
        ex = extract_block(sec["lines"])
        if not ex["found"]:
            noblock.append(sec["name"])
        elif not ex["closed"] or ex["trailing_after"]:
            approx = len(("\n".join(sec["lines"])).encode("utf-8", "surrogateescape"))
            broken.append({"file": sec["name"], "lines_after_early_close": len(ex.get("trailing_after", [])),
                           "section_bytes_approx": approx,
                           "first_leaked": (ex.get("trailing_after") or [""])[0][:80]})
        else:
            intact.append(sec["name"])
    print(f"diagnose {doc_path}: {len(sections)} sections — intact: {len(intact)}, BROKEN: {len(broken)}, no-block: {len(noblock)}")
    for b in broken:
        print(f"  [BROKEN] {b['file']}: {b['lines_after_early_close']} line(s) leaked outside the fence "
              f"(~{b['section_bytes_approx']} B in section); first leaked: {b['first_leaked']!r}")
    for n in intact:
        print(f"  [intact] {n}")
    if noblock:
        print(f"  [no-block] {noblock}")
    if broken:
        print("Verdict: pre-v4 fixed-rank fencing — bytes are present in the document but NOT")
        print("recoverable by conformant parsers for the BROKEN files. Re-generate with ctf v4+")
        print("(dynamic fence rank) and verify with this tool; or recover from the original sources.")
    if json_out:
        json_out.write_text(json.dumps({"broken": broken, "intact": intact, "no_block": noblock},
                                       indent=1, ensure_ascii=False))
    return 1 if broken else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="round-trip verifier / diagnoser for ctf aggregates")
    ap.add_argument("doc", help="the aggregate markdown document")
    ap.add_argument("--sources", help="original files dir for byte-exact comparison")
    ap.add_argument("--diagnose", action="store_true", help="forensics for pre-v4 (metadata-less) documents")
    ap.add_argument("--json", help="write a machine-readable report")
    a = ap.parse_args()
    doc = Path(a.doc)
    if not doc.is_file():
        print(f"no such document: {doc}", file=sys.stderr)
        return 2
    json_out = Path(a.json) if a.json else None
    if a.diagnose:
        return diagnose(doc, json_out)
    return verify(doc, Path(a.sources) if a.sources else None, json_out)


if __name__ == "__main__":
    sys.exit(main())
