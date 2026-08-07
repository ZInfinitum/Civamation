#!/usr/bin/env python3
"""Static audit for Civamation.  One command, several checks.

    python3 tools/audit.py            # everything
    python3 tools/audit.py --list     # advisory checks print every hit
    python3 tools/audit.py --quick    # skip whole-project scans

Exit code is non-zero only when a **hard** check fails.  Advisory checks print
and never fail the build - see the table in `main()`, which is the one place
that decides which is which, so promoting a check to a gate is a one-word diff.

Why these checks and not others
-------------------------------
The compiler already catches syntax and most type errors, and the headless
harness catches "the game fell over".  What neither catches is code and data
that parse, run, and are silently wrong in the domain - so that is all this
looks for:

  * an id referenced by a string that nothing declares.  GDScript will not warn
    about `"requires": ["trackwayz"]`; the tech is simply never unlockable and
    the road tier it gates is dead for ever.
  * a constant nothing reads.  SETTLEMENT_BASE_COST outlived the floors it
    described by one commit and had to be found by hand.
  * a yield multiplier keyed to a trade that `_mult()` never asks about, so the
    number in the table is decoration.
  * a documented count that the data no longer produces.  This document set
    states "37 techs" and "14 biomes" in several places and nothing but a human
    has ever checked them.

Opt-out convention
------------------
Any flagged line can be exempted with a marker on that line or the one above:

    # audit-ok: <check-name> - why

The reason after the dash is mandatory; a bare marker teaches nothing and never
gets revisited.  Lookback is deliberately two lines, so a marker cannot drift
away from its target during a refactor and quietly suppress a new bug.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BALANCE = os.path.join(ROOT, "scripts", "autoload", "Balance.gd")

# Directories whose .gd files are game code (as opposed to tools).
CODE_DIRS = ["scripts"]
DOC_DIR = "docs"


# --- plumbing ---------------------------------------------------------------

class Result:
    def __init__(self, name, hard):
        self.name = name
        self.hard = hard
        self.hits = []
        self.note = ""

    def hit(self, where, what):
        self.hits.append((where, what))

    def ok(self):
        return not self.hits


def gd_files():
    out = []
    for d in CODE_DIRS:
        for base, _, names in os.walk(os.path.join(ROOT, d)):
            for n in names:
                if n.endswith(".gd"):
                    out.append(os.path.join(base, n))
    return sorted(out)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(text):
    """Remove line comments and docstrings.

    A check satisfied by comment prose is a check that passes on broken code -
    the audit doc this toolkit came from lists that as the first anti-pattern,
    and it had already happened once there.
    """
    out = []
    for line in text.split("\n"):
        # Not string-aware, which is fine: a '#' inside a GDScript string is
        # rare and the worst case is that we drop a fragment we were not going
        # to match on anyway.
        out.append(line.split("#", 1)[0])
    return "\n".join(out)


def exempt(lines, index, check):
    """True when this line carries an opt-out marker for this check."""
    for k in (index, index - 1):
        if k < 0 or k >= len(lines):
            continue
        # The comment syntax differs by file type - '#' in GDScript, '<!--' in
        # Markdown - so match the marker itself rather than the comment opener.
        m = re.search(r"audit-ok:\s*([\w-]+)\s*-\s*(\S.*)", lines[k])
        if m and m.group(1) == check:
            return True
    return False


# --- reading Balance.gd -----------------------------------------------------
# Balance.gd is a GDScript literal, not data, so this is deliberately shallow:
# it pulls out top-level dictionary keys and the string ids referenced inside,
# which is all the cross-reference checks need.  Parsing it properly would mean
# writing a GDScript parser, and the failure it would buy is not one that has
# ever happened here.

def block_of(text, const_name):
    """The source text of `const NAME := { ... }` or `[ ... ]`."""
    m = re.search(r"const\s+%s\s*(?::\s*\w+(?:\[\w+\])?)?\s*:?=\s*([\{\[])"
                  % re.escape(const_name), text)
    if not m:
        return ""
    open_ch = m.group(1)
    close_ch = "}" if open_ch == "{" else "]"
    depth = 0
    start = m.end() - 1
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def top_keys(block):
    """Quoted keys at nesting depth 1 of a dictionary block."""
    keys = []
    depth = 0
    i = 0
    while i < len(block):
        c = block[i]
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
        elif c == '"' and depth == 1:
            j = block.find('"', i + 1)
            if j < 0:
                break
            token = block[i + 1:j]
            rest = block[j + 1:j + 40].lstrip()
            if rest.startswith(":"):
                keys.append(token)
            i = j
        i += 1
    return keys


def strings_under(block, field):
    """Every quoted string appearing in `"field": ...` entries of a block."""
    out = []
    for m in re.finditer(r'"%s"\s*:\s*(\[[^\]]*\]|"[^"]*")' % re.escape(field), block):
        out.extend(re.findall(r'"([^"]*)"', m.group(1)))
    return out


# --- checks -----------------------------------------------------------------

def check_id_references(bal):
    """Every id referenced by string must be declared somewhere.

    The single highest-yield class of bug in a data-driven project: a typo in
    a `requires` list costs nothing at parse time and makes the content
    permanently unreachable.
    """
    r = Result("id-refs", hard=True)
    techs = set(top_keys(block_of(bal, "TECHS")))
    jobs = set(top_keys(block_of(bal, "JOBS")))
    buildings = set(top_keys(block_of(bal, "BUILDINGS")))
    resources = set(top_keys(block_of(bal, "RESOURCES")))

    if not techs or not buildings:
        r.hit(BALANCE, "could not read TECHS/BUILDINGS - the parser needs updating")
        return r

    # Tech prerequisites.
    for name in strings_under(block_of(bal, "TECHS"), "requires"):
        if name and name not in techs:
            r.hit("TECHS", "a tech requires '%s', which is not a tech" % name)
    # Buildings and jobs gated on techs.
    for const, ids in (("BUILDINGS", buildings), ("JOBS", jobs)):
        for name in strings_under(block_of(bal, const), "requires"):
            if name and name not in techs:
                r.hit(const, "'%s' requires tech '%s', which does not exist" % (const, name))
    # Ore and road ladders name the tech that unlocks each rung.
    for const in ("ORE_TIERS", "ROAD_TIERS"):
        blk = block_of(bal, const)
        if not blk:
            continue
        for name in strings_under(blk, "tech"):
            if name and name not in techs:
                r.hit(const, "tier gated on tech '%s', which does not exist" % name)
    # Building costs are denominated in resources.
    for m in re.finditer(r'"cost"\s*:\s*\{([^}]*)\}', block_of(bal, "BUILDINGS")):
        for name in re.findall(r'"([a-z_]+)"\s*:', m.group(1)):
            if name not in resources:
                r.hit("BUILDINGS", "a cost is denominated in '%s', which is not a resource" % name)
    # Every ordering list must name things that exist.
    for const, universe, label in (
            ("JOB_ORDER", jobs, "job"),
            ("BUILDING_ORDER", buildings, "building"),
            ("RESOURCE_ORDER", resources, "resource")):
        blk = block_of(bal, const)
        for name in re.findall(r'"([^"]+)"', blk):
            if name not in universe:
                r.hit(const, "lists '%s', which is not a %s" % (name, label))
        for name in universe:
            if blk and ('"%s"' % name) not in blk:
                r.hit(const, "does not list the %s '%s'" % (label, name))
    return r


def check_yield_kinds(bal, code):
    """A yield multiplier keyed to a trade nothing reads is decoration.

    `_mult(kind)` is asked for a fixed vocabulary of trade kinds.  A table entry
    under any other key is applied to nothing, silently, for ever.
    """
    r = Result("yield-kinds", hard=True)
    kinds = set(re.findall(r'"kind"\s*:\s*"([a-z_]+)"', block_of(bal, "JOBS")))
    # Kinds the simulation asks about directly, beyond the job kinds.
    kinds |= {"knowledge", "housing_mult", "build"}
    if not kinds:
        return r
    for const in ("TECHS", "BUILDINGS", "SEASONS", "WEATHER", "DECREES", "UPGRADE_NAMES"):
        blk = block_of(bal, const)
        for m in re.finditer(r'"(?:yield_)?mult"\s*:\s*\{([^}]*)\}', blk):
            for name in re.findall(r'"([a-z_]+)"\s*:', m.group(1)):
                if name not in kinds:
                    r.hit(const, "multiplies '%s', which is not a trade kind" % name)
    return r


def check_dead_constants(bal, code, listing):
    """Constants in Balance.gd that nothing reads.

    Balance.gd is the tuning surface, so a constant nobody reads is a number
    that looks live and is not.  Advisory, because a constant can legitimately
    be read only from a doc or kept for an imminent feature - but every hit
    wants a human glance.
    """
    r = Result("dead-constants", hard=False)
    lines = bal.split("\n")
    names = []
    for i, line in enumerate(lines):
        m = re.match(r"const\s+([A-Z][A-Z0-9_]*)\s*", line)
        if m and not exempt(lines, i, "dead-constants"):
            names.append(m.group(1))
    haystack = code + strip_comments(bal)
    for name in names:
        uses = len(re.findall(r"\b%s\b" % name, haystack))
        # One use is the declaration itself.
        if uses <= 1:
            r.hit("Balance.gd", name)
    if r.hits and not listing:
        r.note = "%d unread; --list to see them" % len(r.hits)
    return r


def check_signals(code_by_file):
    """Signals nothing listens to, and connections to signals nothing emits."""
    r = Result("signals", hard=False)
    declared, emitted, connected = {}, set(), set()
    for path, text in code_by_file.items():
        body = strip_comments(text)
        for name in re.findall(r"^signal\s+(\w+)", body, re.M):
            declared[name] = path
        emitted |= set(re.findall(r"(\w+)\.emit\s*\(", body))
        connected |= set(re.findall(r"(\w+)\.connect\s*\(", body))
    for name, path in sorted(declared.items()):
        if name not in connected:
            r.hit(os.path.relpath(path, ROOT), "signal '%s' has no listener" % name)
        if name not in emitted:
            r.hit(os.path.relpath(path, ROOT), "signal '%s' is never emitted" % name)
    return r


def check_art_coverage(bal, listing):
    """Wired / declared / present, kept as three columns rather than one number.

    Collapsing them hides the only interesting state.  Wired + declared +
    missing is normal and expected here - the game draws a primitive instead.
    A file present under a name nothing will ever ask for is the actual bug,
    because it looks like art that shipped and is never drawn.
    """
    r = Result("art", hard=False)
    expected = {
        "terrain": [n.lower().replace(" ", "_") for n in
                    re.findall(r'"name"\s*:\s*"([^"]+)"', block_of(bal, "BIOME_INFO"))],
        "buildings": top_keys(block_of(bal, "BUILDINGS")),
        "workers": top_keys(block_of(bal, "JOBS")),
        "resources": top_keys(block_of(bal, "RESOURCES")),
        "animals": [n.lower() for n in
                    re.findall(r'"name"\s*:\s*"([^"]+)"', block_of(bal, "ANIMALS"))],
    }
    lines = []
    for cat, ids in expected.items():
        d = os.path.join(ROOT, "assets", cat)
        have = set()
        if os.path.isdir(d):
            have = {os.path.splitext(n)[0].lower() for n in os.listdir(d)
                    if not n.startswith(".")}
        ids = [i for i in ids if i]
        want = {i.lower() for i in ids}
        present = want & have
        orphan = have - want
        lines.append("    %-10s %3d/%-3d present%s"
                     % (cat, len(present), len(want),
                        ("   %d orphan: %s" % (len(orphan), ", ".join(sorted(orphan))))
                        if orphan else ""))
        for o in sorted(orphan):
            r.hit("assets/%s" % cat, "'%s' matches no id - it will never be drawn" % o)
    r.note = "\n" + "\n".join(lines)
    return r


def check_doc_facts(bal):
    """Documented counts against what the data actually contains.

    Numbers transcribed by hand rot.  This document set states counts in half a
    dozen places and only a human has ever checked them.
    """
    r = Result("doc-facts", hard=True)
    counts = {
        "techs": len(top_keys(block_of(bal, "TECHS"))),
        "buildings": len(top_keys(block_of(bal, "BUILDINGS"))),
        "trades": len(top_keys(block_of(bal, "JOBS"))),
        "resources": len(top_keys(block_of(bal, "RESOURCES"))),
        "biomes": len(re.findall(r'"name"\s*:', block_of(bal, "BIOME_INFO"))),
        "eras": len(re.findall(r'"name"\s*:', block_of(bal, "ERAS"))),
    }
    # Claims of the form "<number> <thing>", written as digits or as words we
    # actually use.  Only the shapes the docs really contain, so this stays a
    # check rather than a guessing game.
    words = {
        "thirty-five": 35, "thirty-six": 36, "thirty-seven": 37, "thirty-eight": 38,
        "eleven": 11, "fourteen": 14, "nine": 9, "eight": 8, "twenty-one": 21,
        "twenty-two": 22, "twenty-three": 23,
    }
    docs = []
    for base, _, names in os.walk(os.path.join(ROOT, DOC_DIR)):
        for n in names:
            if n.endswith(".md"):
                docs.append(os.path.join(base, n))
    docs.append(os.path.join(ROOT, "README.md"))

    nouns = {"techs": ["technologies", "techs"], "buildings": ["buildings"],
             "trades": ["trades"], "resources": ["resources"],
             "biomes": ["biomes"], "eras": ["eras"]}
    for path in docs:
        if not os.path.exists(path):
            continue
        lines = read(path).split("\n")
        for i, line in enumerate(lines):
            if exempt(lines, i, "doc-facts"):
                continue
            low = line.lower()
            for key, real in counts.items():
                for noun in nouns[key]:
                    for m in re.finditer(r"([\w-]+)\s+%s\b" % noun, low):
                        tok = m.group(1)
                        val = None
                        if tok.isdigit():
                            val = int(tok)
                        elif tok in words:
                            val = words[tok]
                        if val is not None and val != real:
                            r.hit("%s:%d" % (os.path.relpath(path, ROOT), i + 1),
                                  "says %s %s, data has %d" % (tok, noun, real))
    return r


# --- runner -----------------------------------------------------------------

def main():
    listing = "--list" in sys.argv
    quick = "--quick" in sys.argv

    bal = read(BALANCE)
    code_by_file = {p: read(p) for p in gd_files()}
    code = strip_comments("\n".join(code_by_file.values()))

    results = [
        check_id_references(bal),
        check_yield_kinds(bal, code),
        check_doc_facts(bal),
    ]
    if not quick:
        results += [
            check_dead_constants(bal, code, listing),
            check_signals(code_by_file),
            check_art_coverage(bal, listing),
        ]

    failed = 0
    print("Civamation audit")
    print("-" * 66)
    for r in results:
        tag = "HARD " if r.hard else "advis"
        state = "ok" if r.ok() else ("%d" % len(r.hits))
        print("  [%s] %-16s %s" % (tag, r.name, state))
        if r.note:
            print(r.note if r.note.startswith("\n") else "    " + r.note)
        if r.hits and (r.hard or listing):
            for where, what in r.hits[: (999 if listing else 12)]:
                print("      %s: %s" % (where, what))
            if not listing and len(r.hits) > 12:
                print("      ... %d more (--list)" % (len(r.hits) - 12))
        if r.hits and r.hard:
            failed += 1
    print("-" * 66)
    print("FAIL - %d hard check(s)" % failed if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
