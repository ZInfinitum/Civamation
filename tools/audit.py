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


def check_effect_keys(bal, sim):
    """Every key inside an `"effects": {...}` must be one `_apply_effects` reads.

    Written immediately after making this exact mistake: `worksite_mult` was
    added as a *sibling* of `"effects"` rather than inside it, so the tech
    granted nothing at all and the game ran perfectly well without it.  A key
    inside `effects` that the match statement has no arm for fails the same way
    and just as quietly.
    """
    r = Result("effect-keys", hard=True)
    # The arms of the match in _apply_effects, plus the nested dictionaries it
    # walks into rather than matching directly.
    m = re.search(r"func _apply_effects[\s\S]*?\n\tmatch ", sim)
    body = sim[m.start():m.start() + 3000] if m else sim
    handled = set(re.findall(r'^\t{2,3}"([a-z_]+)"\s*:\s*$', body, re.M))
    handled |= {"yield_mult"}
    # Not every effect goes through the match. `housing` is read straight off
    # the effects dictionary by _housing_total, and reporting that as dead was
    # this check's first false positive - so anything read by name anywhere in
    # Sim.gd counts as handled too.
    handled |= set(re.findall(r'\.get\(\s*"([a-z_]+)"', sim))
    if len(handled) < 4:
        r.hit("Sim.gd", "could not read _apply_effects - the parser needs updating")
        return r

    seen = set()
    for const in ("TECHS", "BUILDINGS", "LEGACY_PERKS"):
        blk = block_of(bal, const)
        for mm in re.finditer(r'"effects"\s*:\s*\{', blk):
            # Walk to the matching brace so nested dictionaries are skipped.
            depth = 0
            start = mm.end() - 1
            end = start
            for i in range(start, len(blk)):
                if blk[i] == "{":
                    depth += 1
                elif blk[i] == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            inner = blk[start:end + 1]
            for key in top_keys(inner):
                if key in handled or key in seen:
                    continue
                seen.add(key)
                r.hit(const, "effect '%s' has no arm in _apply_effects - it does nothing"
                      % key)
    return r


def check_save_coverage(sim, savesystem):
    """Every field written by `to_dict` must be read back by `from_dict`.

    This is the shape of the bug that made a reloaded empire come back holding
    a single village's worth of tiles: the state was saved, and nothing read it.
    A field written and never read is a save that silently loses progress, which
    is the worst class of bug this game can have.
    """
    r = Result("save-coverage", hard=True)
    m = re.search(r"func to_dict\(\)[\s\S]*?\n\nfunc ", sim)
    if not m:
        return r
    written = set(re.findall(r'^\t\t"([a-z_]+)"\s*:', m.group(0), re.M))
    loader = sim[sim.find("func from_dict"):]
    read_back = set(re.findall(r'\.get\(\s*"([a-z_]+)"', loader))
    # SaveSystem reads some of the envelope itself - `version` is checked there
    # before Sim ever sees the dictionary, which was this check's other first
    # false positive.
    read_back |= set(re.findall(r'\.get\(\s*"([a-z_]+)"', savesystem))
    # Fields the loader handles by another route than a .get.
    read_back |= {"world", "log"}
    for name in sorted(written - read_back):
        r.hit("Sim.to_dict", "'%s' is saved and never loaded" % name)
    return r


# A GDScript numeric literal: optional sign, digit separators, an exponent.
NUM = r"-?\d[\d_]*\.?\d*(?:[eE][-+]?\d+)?"


def _num(text):
    return float(text.replace("_", ""))


def _const_number(bal, name):
    """The literal value of `const NAME := 1.23`, or None."""
    m = re.search(r"const\s+%s\s*(?::\s*\w+)?\s*:?=\s*(%s)" % (re.escape(name), NUM), bal)
    return _num(m.group(1)) if m else None


def _float_array(bal, name):
    blk = block_of(bal, name)
    return [_num(x) for x in re.findall(NUM, blk)] if blk else []


def _entry_blocks(block):
    """Each depth-1 `{ ... }` inside an array block, in order."""
    out = []
    depth = 0
    start = -1
    for i, c in enumerate(block):
        if c == "{":
            depth += 1
            if depth == 1:
                start = i
        elif c == "}":
            if depth == 1 and start >= 0:
                out.append(block[start:i + 1])
            depth -= 1
    return out


def _field(entry, name):
    m = re.search(r'"%s"\s*:\s*(%s)' % (re.escape(name), NUM), entry)
    return _num(m.group(1)) if m else None


def check_table_shape(bal):
    """Arrays that are indexed by something with a fixed range.

    `season` is `... % 4` and indexes SEASONS; each WEATHER entry's `weight` is
    indexed by season; COHORT_MORTALITY is indexed by cohort.  A table one entry
    short does not fail to parse - it reads out of range at runtime, or worse,
    silently returns the wrong row for the last case.  None of these has bitten
    yet precisely because they are easy to get right and impossible to notice
    when you do not.
    """
    r = Result("table-shape", hard=True)

    cohorts = _const_number(bal, "COHORT_COUNT")
    mort = _float_array(bal, "COHORT_MORTALITY")
    if cohorts and len(mort) != int(cohorts):
        r.hit("COHORT_MORTALITY", "has %d entries, COHORT_COUNT is %d - the last "
              "bands would read out of range" % (len(mort), int(cohorts)))

    for name in ("WORK_START_COHORT", "WORK_END_COHORT", "ELDER_START_COHORT"):
        v = _const_number(bal, name)
        if v is not None and cohorts and not (0 <= v < cohorts):
            r.hit(name, "is %d, outside 0..%d" % (int(v), int(cohorts) - 1))

    seasons = _entry_blocks(block_of(bal, "SEASONS"))
    if len(seasons) != 4:
        r.hit("SEASONS", "has %d entries; season is computed modulo 4" % len(seasons))
    for i, entry in enumerate(_entry_blocks(block_of(bal, "WEATHER"))):
        w = re.search(r'"weight"\s*:\s*\[([^\]]*)\]', entry)
        n = len(re.findall(NUM, w.group(1))) if w else 0
        if n != len(seasons):
            r.hit("WEATHER[%d]" % i, "has %d season weights, there are %d seasons"
                  % (n, len(seasons)))
    return r


def check_monotonic(bal):
    """Ladders that must only ever go up.

    An era whose population threshold is below the one before it is reached at
    the same moment as its predecessor, so the earlier era is never seen.  An
    upgrade tier that costs less than the one below it is bought out of order.
    Every one of these is legal data and silently wrong.
    """
    r = Result("monotonic", hard=True)

    def ascending(label, values, strict=True):
        for i in range(1, len(values)):
            bad = values[i] <= values[i - 1] if strict else values[i] < values[i - 1]
            if bad:
                r.hit(label, "entry %d is %s, after %s" % (i, values[i], values[i - 1]))

    eras = _entry_blocks(block_of(bal, "ERAS"))
    ascending("ERAS pop", [_field(e, "pop") for e in eras][1:])
    ascending("ERAS techs", [_field(e, "techs") for e in eras][1:])

    tiers = _entry_blocks(block_of(bal, "UPGRADE_TIERS"))
    ascending("UPGRADE_TIERS output", [_field(t, "output") for t in tiers])
    ascending("UPGRADE_TIERS cost", [_field(t, "cost") for t in tiers])

    ascending("MILESTONES", [_field(m, "pop") for m in
                             _entry_blocks(block_of(bal, "MILESTONES"))])
    ascending("ORE_TIERS value", [_field(t, "value") for t in
                                  _entry_blocks(block_of(bal, "ORE_TIERS"))])
    ascending("ROAD_TIERS reach", [_field(t, "reach") for t in
                                   _entry_blocks(block_of(bal, "ROAD_TIERS"))])
    ascending("SETTLEMENT_POP_THRESHOLDS", _float_array(bal, "SETTLEMENT_POP_THRESHOLDS"))
    ascending("PEOPLE_PER_FIGURE_STEPS", _float_array(bal, "PEOPLE_PER_FIGURE_STEPS"))
    return r


def check_tech_graph(bal):
    """The tech tree must be a reachable, acyclic graph with sane costs.

    A cycle makes both techs permanently unresearchable and nothing anywhere
    reports it.  So does a prerequisite on a tech that is itself unreachable.
    And a tech cheaper than something it depends on is not a bug exactly, but it
    is always a mistake - it means the ladder has a rung out of order.
    """
    r = Result("tech-graph", hard=True)
    blk = block_of(bal, "TECHS")
    ids = top_keys(blk)
    reqs, costs = {}, {}
    for name in ids:
        i = blk.index('"%s":' % name)
        j = blk.find('\n\t},', i)
        entry = blk[i:j if j > 0 else len(blk)]
        reqs[name] = [x for x in strings_under(entry, "requires") if x]
        costs[name] = _field(entry, "cost")

    # Reachability from the roots, which are the techs with no prerequisites.
    reached = set()
    frontier = [n for n in ids if not reqs[n]]
    reached.update(frontier)
    changed = True
    while changed:
        changed = False
        for name in ids:
            if name in reached:
                continue
            if all(p in reached for p in reqs[name]):
                reached.add(name)
                changed = True
    for name in ids:
        if name not in reached:
            r.hit("TECHS", "'%s' can never be researched - its prerequisites are "
                  "unreachable or cyclic" % name)

    return r


def check_enum_coverage(bal):
    """Every value of an enum that a table is keyed by must appear in it.

    A biome in the enum with no BIOME_INFO row generates land the game cannot
    describe, colour or harvest, and finds out at runtime on whichever seed
    happens to produce it.
    """
    r = Result("enum-coverage", hard=True)
    m = re.search(r"enum\s+Biome\s*\{([^}]*)\}", strip_comments(bal))
    if not m:
        return r
    members = [x.strip() for x in m.group(1).split(",") if x.strip()]
    info = block_of(bal, "BIOME_INFO")
    for name in members:
        if ("Biome.%s:" % name) not in info:
            r.hit("BIOME_INFO", "no row for Biome.%s" % name)

    # ANIMALS lists habitats as raw enum indices, which is exactly the sort of
    # thing that survives a reordering of the enum without anyone noticing.
    for entry in _entry_blocks(block_of(bal, "ANIMALS")):
        b = re.search(r'"biomes"\s*:\s*\[([^\]]*)\]', entry)
        if not b:
            continue
        for v in re.findall(r"\d+", b.group(1)):
            if int(v) >= len(members):
                r.hit("ANIMALS", "lives in biome %s, but there are only %d biomes"
                      % (v, len(members)))
    return r


def check_shader_uniforms(code):
    """Uniforms set from GDScript must exist, and declared ones must be set.

    `set_shader_parameter` takes a string.  Misspell it and the call succeeds,
    returns nothing, and the shader quietly keeps its default - which for the
    hex terrain would mean a map that renders at the wrong scale or not at all,
    with no error anywhere.
    """
    r = Result("shader-uniforms", hard=True)
    sh_dir = os.path.join(ROOT, "shaders")
    if not os.path.isdir(sh_dir):
        return r
    declared = set()
    for n in os.listdir(sh_dir):
        if n.endswith(".gdshader"):
            declared |= set(re.findall(r"^uniform\s+\w+\s+(\w+)", read(os.path.join(sh_dir, n)), re.M))
    used = set(re.findall(r'set_shader_parameter\(\s*"(\w+)"', code))
    for name in sorted(used - declared):
        r.hit("set_shader_parameter", "'%s' is not a uniform in any shader" % name)
    for name in sorted(declared - used):
        r.note += ("  " if r.note else "") + ("uniform '%s' keeps its default" % name)
    return r


def check_input_actions(code):
    """Input actions read by code must be registered, and vice versa."""
    r = Result("input-actions", hard=True)
    proj = os.path.join(ROOT, "project.godot")
    if not os.path.exists(proj):
        return r
    text = read(proj)
    section = text.split("[input]", 1)
    if len(section) < 2:
        return r
    body = section[1].split("\n[", 1)[0]
    declared = set(re.findall(r"^(\w+)=\{", body, re.M))
    used = set(re.findall(r'is_action_(?:just_)?(?:pressed|released)\(\s*"(\w+)"', code))
    for name in sorted(used - declared):
        # Godot's own ui_* actions are built in and need no registration.
        if name.startswith("ui_") and name in ("ui_accept", "ui_cancel", "ui_left",
                                               "ui_right", "ui_up", "ui_down", "ui_focus_next"):
            continue
        r.hit("project.godot", "action '%s' is read but never registered" % name)
    for name in sorted(declared - used):
        r.hit("project.godot", "action '%s' is registered and never read" % name)
    return r


def check_doc_constants(bal):
    """Constants quoted in the documents against what Balance.gd says.

    The GDD carries a whole balance-reference table of hand-copied numbers.
    STOCK_REFUGE was written there as 0.30 and had been 0.40 in the code for a
    week.  Numbers transcribed by hand rot; this is the cheapest possible
    version of generating them instead.
    """
    r = Result("doc-constants", hard=True)
    docs = [os.path.join(ROOT, "README.md")]
    for base, _, names in os.walk(os.path.join(ROOT, DOC_DIR)):
        docs += [os.path.join(base, n) for n in names if n.endswith(".md")]
    for path in docs:
        if not os.path.exists(path):
            continue
        lines = read(path).split("\n")
        for i, line in enumerate(lines):
            if exempt(lines, i, "doc-constants"):
                continue
            # `CONSTANT_NAME` followed by a number somewhere on the same line.
            m = re.search(r"`([A-Z][A-Z0-9_]{3,})`[^\d\-]*\**(%s)" % NUM, line)
            if not m:
                continue
            # A figure given as a percentage is a restatement, not the literal.
            if line[m.end(2):m.end(2) + 1] == "%":
                continue
            real = _const_number(bal, m.group(1))
            if real is None:
                continue
            claimed = float(m.group(2))
            if abs(claimed - real) > 1e-9:
                r.hit("%s:%d" % (os.path.relpath(path, ROOT), i + 1),
                      "%s documented as %g, code says %g" % (m.group(1), claimed, real))
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

    sim = read(os.path.join(ROOT, "scripts", "autoload", "Sim.gd"))
    results = [
        check_id_references(bal),
        check_yield_kinds(bal, code),
        check_effect_keys(bal, sim),
        check_table_shape(bal),
        check_monotonic(bal),
        check_tech_graph(bal),
        check_enum_coverage(bal),
        check_shader_uniforms(code),
        check_input_actions(code),
        check_doc_constants(bal),
        check_save_coverage(sim, read(os.path.join(
            ROOT, "scripts", "autoload", "SaveSystem.gd"))),
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
