#!/usr/bin/env python3
"""Checks every relative link and heading anchor in the tracked Markdown files.

  scripts/check-doc-links.py              check the repository (exit 1 if a link is broken)
  scripts/check-doc-links.py --self-test  check the anchor rules against known GitHub examples

Why: an anchor written from memory is easy to get wrong (GitHub drops punctuation such as the slash in "active/active", so the
anchor for "Multi-region, active/active" is "multi-region-activeactive"), and the link then silently goes nowhere. The check is
offline, standard library only, and used by CI (validate.yml) and by hand.

Checked: links to files (they must exist) and to headings (#anchor, in the same or another Markdown file). Not checked:
http(s) links, and anything inside code fences or inline code. Anchors follow GitHub's rules: lower-case, punctuation removed
except hyphens and underscores, spaces become hyphens, and a repeated heading gets -1, -2, ...
"""
import os
import re
import subprocess
import sys

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]*)\)")          # [text](target); images are skipped
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def slug(heading):
    """GitHub's anchor for a heading."""
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)       # [text](url) -> text
    h = re.sub(r"<[^>]+>", "", h)                               # inline HTML
    h = re.sub(r"[`*]", "", h).strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)                              # \w keeps letters, digits and underscore
    return h.replace(" ", "-")


def anchors_of(lines):
    seen, out, fenced = {}, set(), False
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
            continue
        m = None if fenced else HEADING.match(line)
        if m:
            s = slug(m.group(2))
            n = seen.get(s, 0)
            seen[s] = n + 1
            out.add(s if n == 0 else f"{s}-{n}")
    return out


def strip_code(lines):
    """Drop fenced blocks and inline code so links in examples are not checked."""
    out, fenced = [], False
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
            out.append("")
        else:
            out.append("" if fenced else re.sub(r"`[^`]*`", "", line))
    return out


def check_contents(contents):
    """contents: {path: [lines]} of Markdown files. Returns a list of problem strings."""
    contents = {os.path.normpath(f): lines for f, lines in contents.items()}
    anchors = {f: anchors_of(lines) for f, lines in contents.items()}
    problems = []
    for f, lines in contents.items():
        for n, line in enumerate(strip_code(lines), 1):
            for m in LINK.finditer(line):
                target = m.group(1)
                if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):   # http:, https:, mailto:, ...
                    continue
                path, _, frag = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
                if not (os.path.exists(dest) or dest in contents):
                    problems.append(f"{f}:{n}: file not found: {target}")
                elif frag and dest.endswith(".md") and frag.lower() not in anchors.get(dest, set()):
                    problems.append(f"{f}:{n}: no heading for anchor: {target}")
    return problems


def check(files):
    return check_contents({f: open(f, encoding="utf-8").read().splitlines() for f in files})


def self_test():
    cases = {
        "Multi-region, active/active: global table (optional, billed, OFF by default)": "multi-region-activeactive-global-table-optional-billed-off-by-default",
        "7. Multi-region active/active (optional, billed)": "7-multi-region-activeactive-optional-billed",
        "What `--private` does": "what---private-does",
        "Why use AWS WAF for rate limiting instead of the API Gateway rate-limiting feature?": "why-use-aws-waf-for-rate-limiting-instead-of-the-api-gateway-rate-limiting-feature",
        'Where does the "shared bucket" in API Gateway throttling come from?': "where-does-the-shared-bucket-in-api-gateway-throttling-come-from",
        "[Link](x.md) in a heading": "link-in-a-heading",
    }
    failures = [f"slug({h!r}) = {slug(h)!r}, expected {want!r}" for h, want in cases.items() if slug(h) != want]
    if anchors_of(["# A", "## A", "## A"]) != {"a", "a-1", "a-2"}:
        failures.append("repeated headings do not get -1, -2")
    if anchors_of(["```", "# not a heading", "```", "# real"]) != {"real"}:
        failures.append("headings inside code fences are counted")
    got = check_contents({"a.md": ["# One", "[ok](#one) [bad](#two) [file](missing.md) [web](https://x.y/#z) `[code](#nope)`"]})
    want = ["a.md:2: no heading for anchor: #two", "a.md:2: file not found: missing.md"]
    if sorted(got) != sorted(want):
        failures.append(f"link checking gave {got}")
    # The mistake this check exists for: the slash in "active/active" is dropped from the anchor, so "active-active" is broken.
    got = check_contents({"d.md": ["## Multi-region, active/active: global table"], "r.md": ["[x](d.md#multi-region-active-active-global-table)", "[y](d.md#multi-region-activeactive-global-table)"]})
    if got != ["r.md:1: no heading for anchor: d.md#multi-region-active-active-global-table"]:
        failures.append(f"the active/active mistake was not caught exactly once: {got}")
    if failures:
        print("check-doc-links self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"check-doc-links self-test OK: {len(cases)} anchor rules and the link checks behave as expected.")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    os.chdir(top)
    files = [f for f in subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.splitlines()
             if os.path.exists(f)]
    problems = check(files)
    if problems:
        print(f"check-doc-links: {len(problems)} broken link(s):")
        print("\n".join("  " + p for p in problems))
        return 1
    print(f"check-doc-links: OK, every relative link and anchor resolves in {len(files)} Markdown files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
