#!/usr/bin/env python3
"""Validate and merge English word-pack content.

    python3 scripts/seeds.py check FILE...          # validate chunk files (JSON arrays of entries)
    python3 scripts/seeds.py merge CHUNK_DIR        # merge chunks into VocabLoop/Resources/Seeds

A chunk file is a JSON array of entries in the SeedEntry shape (see SeedPack.swift). Its level is
taken from each entry's "cefr". Merge keeps every entry already in the packs, drops invalid or
duplicate entries (a word judged at two levels goes to the lower one), sorts by frequency rank and
bumps each pack's version so installed apps re-import it.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS = os.path.join(ROOT, "VocabLoop", "Resources", "Seeds")

PACKS = {
    "en_core_a1_a2": {"A1", "A2"},
    "en_core_b1_b2": {"B1", "B2"},
    "en_core_c1": {"C1", "C2"},
}
LEVEL_ORDER = ["A1", "A2", "B1", "B2", "C1", "C2"]
POS = {
    "noun", "verb", "adjective", "adverb", "preposition", "conjunction", "pronoun",
    "determiner", "interjection", "phrasal verb", "idiom", "phrase", "number", "modal verb",
    "auxiliary verb", "article", "exclamation",
}


def surface_forms(headword):
    """Mirror of ClozeMasker.surfaceForms(.englishSuffixes)."""
    base = headword.lower()
    forms = {base}
    if len(base) <= 2:
        return forms
    forms |= {base + s for s in ("s", "es", "ed", "d", "ing", "er", "est")}
    if base.endswith("e"):
        stem = base[:-1]
        forms |= {stem + s for s in ("ing", "ed", "er", "est")}
    if base.endswith("y"):
        stem = base[:-1]
        forms |= {stem + s for s in ("ies", "ied", "ier", "iest")}
    if len(base) >= 3:
        last, middle, first = base[-1], base[-2], base[-3]
        if last not in "aeiouwxy" and middle in "aeiou" and first not in "aeiou":
            forms |= {base + last + s for s in ("ed", "ing", "er", "est")}
    return forms


def example_has_target(headword, example):
    if "cloze" in example and example["cloze"]:
        return "{{" in example["cloze"]
    text = example["text"].lower()
    if " " in headword:
        # ClozeMasker matches single tokens only, so a phrase always needs an authored blank.
        return False
    # Apostrophes count as word characters in ClozeMasker, so a quote mark glued to a word
    # ('Yes) hides it — mirror that rather than being more forgiving than the app.
    tokens = re.findall(r"[a-z']+", text)
    forms = surface_forms(headword)
    return any(t in forms for t in tokens)


def check_entry(e):
    """Return a list of problems (empty when valid)."""
    p = []
    hw = e.get("headword")
    if not isinstance(hw, str) or not hw.strip() or hw != hw.strip():
        return ["missing or untrimmed headword"]
    if not re.fullmatch(r"[a-z][a-z' -]*[a-z]|[a-z]", hw):
        p.append("headword must be lower-case letters (spaces, hyphens, apostrophes allowed)")
    ph = e.get("phonetic")
    if not isinstance(ph, str) or not re.fullmatch(r"/[^/]+/", ph):
        p.append("phonetic must look like /.../")
    if e.get("cefr") not in LEVEL_ORDER:
        p.append("cefr must be one of A1..C2")
    r = e.get("frequencyRank")
    if not isinstance(r, int) or not 1 <= r <= 40000:
        p.append("frequencyRank must be an int 1..40000")
    senses = e.get("senses")
    if not isinstance(senses, list) or not senses:
        return p + ["at least one sense required"]
    for i, s in enumerate(senses):
        tag = f"sense {i + 1}"
        if s.get("partOfSpeech") not in POS:
            p.append(f"{tag}: partOfSpeech {s.get('partOfSpeech')!r} not in {sorted(POS)}")
        if not isinstance(s.get("definition"), str) or len(s["definition"].strip()) < 3:
            p.append(f"{tag}: definition missing")
        zh = (s.get("translations") or {}).get("zh")
        if not isinstance(zh, str) or not zh.strip():
            p.append(f"{tag}: translations.zh missing")
        examples = s.get("examples")
        if i == 0 and (not isinstance(examples, list) or not examples):
            p.append(f"{tag}: at least one example required")
            continue
        for j, ex in enumerate(examples or []):
            if not isinstance(ex.get("text"), str) or not ex["text"].strip():
                p.append(f"{tag} example {j + 1}: text missing")
                continue
            if not (ex.get("translations") or {}).get("zh"):
                p.append(f"{tag} example {j + 1}: translations.zh missing")
            if ex.get("cloze"):
                stripped = ex["cloze"].replace("{{", "").replace("}}", "")
                if stripped != ex["text"] or ex["cloze"].count("{{") != 1:
                    p.append(f"{tag} example {j + 1}: cloze must equal text with exactly one {{{{…}}}}")
        first = (senses[0].get("examples") or [None])[0]
        if i == 0 and first and first.get("text") and not example_has_target(hw, first):
            p.append("first example does not contain the headword or a regular inflection "
                     "(rephrase, or add \"cloze\" marking the irregular form)")
    return p


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get("entries", [])
    return data


def cmd_check(paths):
    bad = 0
    total = 0
    seen = {}
    for path in paths:
        for e in load(path):
            total += 1
            problems = check_entry(e)
            hw = e.get("headword")
            if hw in seen:
                problems.append(f"duplicate of the entry in {seen[hw]}")
            seen.setdefault(hw, os.path.basename(path))
            if problems:
                bad += 1
                print(f"{os.path.basename(path)}: {hw!r}: " + "; ".join(problems))
    print(f"{total} entries, {bad} with problems")
    return 1 if bad else 0


def cmd_merge(chunk_dir):
    packs = {}
    for name in PACKS:
        with open(os.path.join(SEEDS, name + ".json"), encoding="utf-8") as f:
            packs[name] = json.load(f)

    def pack_for(level):
        return next(n for n, levels in PACKS.items() if level in levels)

    # Existing content always wins: it was reviewed by hand.
    owner = {}
    for name, pack in packs.items():
        for e in pack["entries"]:
            owner[e["headword"]] = name

    candidates = {}
    rejected = 0
    for path in sorted(glob.glob(os.path.join(chunk_dir, "*.json"))):
        for e in load(path):
            if check_entry(e):
                rejected += 1
                continue
            hw = e["headword"]
            if hw in owner:
                continue
            prev = candidates.get(hw)
            if prev is None or LEVEL_ORDER.index(e["cefr"]) < LEVEL_ORDER.index(prev["cefr"]):
                candidates[hw] = e

    added = {n: 0 for n in PACKS}
    for hw, e in candidates.items():
        name = pack_for(e["cefr"])
        packs[name]["entries"].append(e)
        added[name] += 1

    for name, pack in packs.items():
        pack["entries"].sort(key=lambda e: (e.get("frequencyRank") or 10**9, e["headword"]))
        pack["version"] = pack["version"] + 1
        with open(os.path.join(SEEDS, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(pack, f, ensure_ascii=False, indent=1)
            f.write("\n")
        print(f"{name}: +{added[name]} → {len(pack['entries'])} entries (v{pack['version']})")
    print(f"rejected {rejected} invalid entries")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "check":
        sys.exit(cmd_check(sys.argv[2:]))
    if len(sys.argv) == 3 and sys.argv[1] == "merge":
        cmd_merge(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
