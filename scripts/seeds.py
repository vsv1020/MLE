#!/usr/bin/env python3
"""Validate and merge word-pack content (English, French, Thai).

    python3 scripts/seeds.py check [--lang en|fr|th] FILE...    # validate chunk files (JSON arrays)
    python3 scripts/seeds.py merge [--lang en|fr|th] CHUNK_DIR  # merge chunks into VocabLoop/Resources/Seeds

--lang defaults to en.

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

PACKS_BY_LANG = {
    "en": {
        "en_core_a1_a2": {"A1", "A2"},
        "en_core_b1_b2": {"B1", "B2"},
        "en_core_c1": {"C1", "C2"},
    },
    # One pack per language for now; every level goes in it.
    "fr": {"fr_starter": {"A1", "A2", "B1", "B2", "C1", "C2"}},
    "th": {"th_starter": {"A1", "A2", "B1", "B2", "C1", "C2"}},
}
PACKS = PACKS_BY_LANG["en"]

HEADWORD_PATTERNS = {
    "en": r"[a-z][a-z' -]*[a-z]|[a-z]",
    # Lower-case French letters, with the apostrophes, hyphens and spaces of
    # "aujourd'hui", "peut-être" and "pomme de terre".
    "fr": r"[a-zàâäçéèêëîïôöùûüÿœæ][a-zàâäçéèêëîïôöùûüÿœæ' -]*[a-zàâäçéèêëîïôöùûüÿœæ]|[a-zàâäçéèêëîïôöùûüÿœæ]",
    # Thai script only (U+0E00–U+0E7F), spaces allowed inside.
    "th": r"[\u0E00-\u0E7F][\u0E00-\u0E7F ]*[\u0E00-\u0E7F]|[\u0E00-\u0E7F]",
}
LEVEL_ORDER = ["A1", "A2", "B1", "B2", "C1", "C2"]
POS = {
    "noun", "verb", "adjective", "adverb", "preposition", "conjunction", "pronoun",
    "determiner", "interjection", "phrasal verb", "idiom", "phrase", "number", "modal verb",
    "auxiliary verb", "article", "exclamation", "particle", "classifier",
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


def fold(text):
    """Mirror of ClozeMasker.fold: case- and diacritic-insensitive."""
    import unicodedata
    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in decomposed if not unicodedata.combining(c)).strip()


def example_has_target(headword, example, lang="en"):
    if "cloze" in example and example["cloze"]:
        return "{{" in example["cloze"]
    if lang == "th":
        # Thai has no spaces between words: ClozeMasker searches for the headword as a substring.
        return headword in example["text"]
    if lang == "fr":
        # exactOnly: a whole token equal to the headword (apostrophes are word characters, so
        # "l'eau" does not contain the token "eau"). A multi-word headword needs an authored blank.
        if " " in headword:
            return False
        tokens = re.findall(r"[\w'\u2019]+", example["text"])
        return any(fold(t) == fold(headword) for t in tokens)
    text = example["text"].lower()
    if " " in headword:
        # ClozeMasker matches single tokens only, so a phrase always needs an authored blank.
        return False
    # Apostrophes count as word characters in ClozeMasker, so a quote mark glued to a word
    # ('Yes) hides it — mirror that rather than being more forgiving than the app.
    tokens = re.findall(r"[a-z']+", text)
    forms = surface_forms(headword)
    return any(t in forms for t in tokens)


def check_entry(e, lang="en"):
    """Return a list of problems (empty when valid)."""
    p = []
    hw = e.get("headword")
    if not isinstance(hw, str) or not hw.strip() or hw != hw.strip():
        return ["missing or untrimmed headword"]
    if not re.fullmatch(HEADWORD_PATTERNS[lang], hw):
        p.append({"th": "headword must be Thai script",
                  "fr": "headword must be lower-case French letters (spaces, hyphens, apostrophes allowed)"}
                 .get(lang, "headword must be lower-case letters (spaces, hyphens, apostrophes allowed)"))
    ph = e.get("phonetic")
    if lang == "th":
        # Thai uses a romanisation (RTGS-style, no tone marks) rather than IPA.
        if not isinstance(ph, str) or not re.fullmatch(r"[a-z][a-z' -]*", ph):
            p.append("phonetic must be a lower-case romanisation like 'sawatdi'")
        tone = (e.get("grammarNotes") or {}).get("toneMarks")
        if not isinstance(tone, str) or "·" not in tone:
            p.append("grammarNotes.toneMarks required, like 'sa-wàt-dii · 低, 低, 中'")
    elif not isinstance(ph, str) or not re.fullmatch(r"/[^/]+/", ph):
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
        if i == 0 and first and first.get("text") and not example_has_target(hw, first, lang):
            p.append("first example does not contain the headword or a regular inflection "
                     "(rephrase, or add \"cloze\" marking the irregular form)")
    return p


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get("entries", [])
    return data


def cmd_check(paths, lang="en"):
    bad = 0
    total = 0
    seen = {}
    for path in paths:
        for e in load(path):
            total += 1
            problems = check_entry(e, lang)
            hw = e.get("headword")
            # The app's stable ID folds case and accents (Entry.normalize), so "ou" and "où"
            # collide unless one carries a homograph number. Thai tone marks are not folded.
            key = (hw if lang == "th" else fold(hw or ""), e.get("homograph", 1))
            if key in seen:
                problems.append(f"duplicate of the entry in {seen[key]} (same headword once accents are ignored; "
                                "add \"homograph\": 2 if both are needed)")
            seen.setdefault(key, os.path.basename(path))
            if problems:
                bad += 1
                print(f"{os.path.basename(path)}: {hw!r}: " + "; ".join(problems))
    print(f"{total} entries, {bad} with problems")
    return 1 if bad else 0


def cmd_merge(chunk_dir, lang="en"):
    PACKS = PACKS_BY_LANG[lang]
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
            if check_entry(e, lang):
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
    args = sys.argv[1:]
    lang = "en"
    if len(args) >= 2 and args[1] == "--lang":
        lang = args[2] if len(args) > 2 else ""
        args = [args[0]] + args[3:]
    if lang not in PACKS_BY_LANG:
        print(f"unknown --lang {lang!r}; use one of {sorted(PACKS_BY_LANG)}")
        sys.exit(2)
    if len(args) >= 2 and args[0] == "check":
        sys.exit(cmd_check(args[1:], lang))
    if len(args) == 2 and args[0] == "merge":
        cmd_merge(args[1], lang)
    else:
        print(__doc__)
        sys.exit(2)
