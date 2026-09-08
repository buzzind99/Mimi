#!/usr/bin/env python3
"""Format probe for the pinned JMDict_Extended asset.

Stream-parses the compiled JMDict_Extended JSON and hard-fails on any
mismatch with the documented input contract — the tripwire against silent
upstream format drift (run before every DB build; also usable standalone
via `scripts/build_jmdict.sh --probe-only`).

Usage: jmdict_probe.py <json_path> <log_path>
Exit 0 = PASS, 1 = FAIL. Full report goes to <log_path>, compact summary
to stdout.
"""

import json
import re
import sys
from collections import Counter


def main(json_path, log_path):
    errors = []
    def fail(msg):
        errors.append(msg)

    def require(cond, msg):
        if not cond:
            fail(msg)
        return cond

    log = open(log_path, "w", encoding="utf-8")
    def out(line=""):
        log.write(line + "\n")

    # Stream the file: BOM stripped, header lines collected, then one word object
    # per line with a trailing comma (even the last one — the file is NOT valid
    # JSON as a whole, which is exactly why we stream instead of json.load).
    with open(json_path, "rb") as raw:
        head = raw.read(3)
        has_bom = head == b"\xef\xbb\xbf"

    out(f"BOM: {'yes (UTF-8)' if has_bom else 'NO'}")
    if has_bom:
        text = open(json_path, encoding="utf-8-sig")
    else:
        text = open(json_path, encoding="utf-8")

    # --- 1. Header ----------------------------------------------------------
    header_keys = {}
    line_no = 0
    words_line = None
    words_remainder = ""
    for line in text:
        line_no += 1
        stripped = line.strip()
        if stripped.startswith('"words"'):
            words_line = line_no
            words_remainder = stripped.split("[", 1)[1] if "[" in stripped else ""
            break
        m = re.match(r'"([A-Za-z]+)"\s*:\s*(.*?),?\s*$', stripped)
        if m:
            header_keys[m.group(1)] = m.group(2)
        elif stripped in ("{", "}"):
            continue
        else:
            fail(f"header line {line_no}: unrecognized layout: {stripped[:80]!r}")

    expected_header = ["version", "languages", "commonOnly", "dictDate",
                       "dictRevisions", "tags"]
    for key in expected_header:
        require(key in header_keys, f"header missing required key {key!r}")
    out(f"Header keys: {sorted(header_keys)}")
    out(f"'words': [ found on line {words_line}")
    require(words_line is not None, "'words': [ line not found")

    try:
        header_json = json.loads("{" + ",".join(
            f'"{k}":{v.rstrip(",")}' for k, v in header_keys.items()) + "}")
        out(f"version={header_json.get('version')} languages={header_json.get('languages')} "
            f"commonOnly={header_json.get('commonOnly')} dictDate={header_json.get('dictDate')} "
            f"dictRevisions={header_json.get('dictRevisions')}")
    except Exception as exc:
        fail(f"header JSON failed to parse: {exc}")

    # --- 2-7. Word stream ---------------------------------------------------
    # One word per line; the FIRST word sits on the "words": [ line itself, and
    # every word line carries a trailing comma (even the last). The file is NOT
    # valid JSON as a whole — stream it, strip, parse per line.
    def word_chunks(fobj, first):
        # The first word sits on the already-consumed "words": [ line.
        if first.strip():
            yield first
        started = True
        for raw in fobj:
            s = raw.strip()
            if s in ("]}", "]"):
                return
            if s:
                yield s

    WORD_KEYS = {"id", "kanji", "kana", "sense"}
    KANJI_KEYS = {"text", "common", "tags", "furigana", "jlptLevel", "pitchAccent"}
    KANA_KEYS = {"text", "common", "tags", "appliesToKanji", "jlptLevel", "pitchAccent"}
    SENSE_KEYS = {"partOfSpeech", "appliesToKanji", "appliesToKana", "misc", "gloss",
                  "related", "antonym", "field", "dialect", "info", "languageSource"}
    GLOSS_KEYS = {"lang", "gender", "type", "text"}
    FURIGANA_KEYS = {"ruby", "rt"}
    PITCH_KEYS = {"hatsuon", "accPatts", "zoPatts"}

    entries = 0
    kanji_obj_count = 0
    kana_obj_count = 0
    kana_only_entries = 0
    kanji_entries = 0
    headword_count = 0
    max_kanji = (0, None)
    max_kana = (0, None)
    id_parse_failures = 0
    word_key_missing = Counter()
    kanji_key_missing = Counter()
    kana_key_missing = Counter()
    sense_key_missing = Counter()
    gloss_key_missing = Counter()
    furigana_bad = 0
    furigana_no_rt = 0
    furigana_count = 0
    jlpt_domain = Counter()
    jlpt_entries = 0
    pitch_entries = 0
    pitch_obj_count = 0
    pitch_is_list_nonempty = 0
    acc_patts_domain = Counter()
    zo_chars = Counter()
    zo_lengths = Counter()
    hatsuon_angle = 0
    hatsuon_no_angle = 0
    applies_kanji_star = 0
    applies_kanji_restricted = 0
    applies_kana_star = 0
    applies_kana_restricted = 0
    applies_kana_empty = 0
    applies_kanji_empty = 0
    gloss_langs = Counter()
    sense_count = 0
    gloss_count = 0
    kanji_common_true = 0
    kana_common_true = 0
    kana_only_common_true = 0
    spot = {"はし": [], "さかな": [], "あめ": []}
    SPOT_MAX = 12

    for stripped in word_chunks(text, words_remainder):
        line_no += 1
        if not stripped:
            continue
        # Trailing comma even on the final word line.
        if stripped.endswith(","):
            stripped = stripped[:-1]
        if not (stripped.startswith("{") and stripped.endswith("}")):
            fail(f"line {line_no}: not a single word object: {stripped[:80]!r}")
            break
        try:
            w = json.loads(stripped)
        except Exception as exc:
            fail(f"line {line_no}: word JSON failed to parse: {exc}")
            break

        entries += 1
        for key in WORD_KEYS:
            if key not in w:
                word_key_missing[key] += 1
        try:
            int(w["id"])
        except (KeyError, ValueError, TypeError):
            id_parse_failures += 1

        kobjs = w.get("kanji") or []
        robjs = w.get("kana") or []
        kanji_obj_count += len(kobjs)
        kana_obj_count += len(robjs)
        headword_count += len(kobjs) + len(robjs)
        if not kobjs and robjs:
            kana_only_entries += 1
        elif kobjs:
            kanji_entries += 1
        if len(kobjs) > max_kanji[0]:
            max_kanji = (len(kobjs), w["id"])
        if len(robjs) > max_kana[0]:
            max_kana = (len(robjs), w["id"])

        entry_has_jlpt = False
        entry_has_pitch = False

        for obj in kobjs:
            for key in KANJI_KEYS:
                if key not in obj:
                    kanji_key_missing[key] += 1
            if obj.get("common") is True:
                kanji_common_true += 1
            fg = obj.get("furigana")
            if not isinstance(fg, list):
                furigana_bad += 1
            else:
                furigana_count += len(fg)
                for fr in fg:
                    # Upstream omits `rt` when the reading equals the ruby.
                    if not isinstance(fr, dict) or "ruby" not in fr:
                        furigana_bad += 1
                    elif "rt" not in fr:
                        furigana_no_rt += 1
            jl = obj.get("jlptLevel")
            if jl is not None:
                if not require(isinstance(jl, int), f"entry {w.get('id')}: kanji jlptLevel not int: {jl!r}"):
                    continue
                jlpt_domain[jl] += 1
                entry_has_jlpt = True
            pa = obj.get("pitchAccent")
            if isinstance(pa, dict):
                if set(pa) != PITCH_KEYS:
                    fail(f"entry {w.get('id')}: kanji pitchAccent keys {sorted(pa)} != {sorted(PITCH_KEYS)}")
                    continue
                pitch_obj_count += 1
                entry_has_pitch = True
                acc_patts_domain[pa["accPatts"]] += 1
                zp = pa["zoPatts"]
                if isinstance(zp, str):
                    zo_lengths[len(zp)] += 1
                    for ch in set(zp):
                        zo_chars[ch] += 1
                hn = pa["hatsuon"]
                if isinstance(hn, str):
                    if "<" in hn or ">" in hn:
                        hatsuon_angle += 1
                    else:
                        hatsuon_no_angle += 1
            elif isinstance(pa, list):
                if pa:
                    pitch_is_list_nonempty += 1
            elif pa is not None:
                fail(f"entry {w.get('id')}: kanji pitchAccent unexpected type {type(pa).__name__}")

        for obj in robjs:
            for key in KANA_KEYS:
                if key not in obj:
                    kana_key_missing[key] += 1
            if obj.get("common") is True:
                kana_common_true += 1
                if not kobjs:
                    kana_only_common_true += 1
            jl = obj.get("jlptLevel")
            if jl is not None:
                if not require(isinstance(jl, int), f"entry {w.get('id')}: kana jlptLevel not int: {jl!r}"):
                    continue
                jlpt_domain[jl] += 1
                entry_has_jlpt = True
            pa = obj.get("pitchAccent")
            if isinstance(pa, dict):
                if set(pa) != PITCH_KEYS:
                    fail(f"entry {w.get('id')}: kana pitchAccent keys {sorted(pa)} != {sorted(PITCH_KEYS)}")
                    continue
                pitch_obj_count += 1
                entry_has_pitch = True
                acc_patts_domain[pa["accPatts"]] += 1
                zp = pa["zoPatts"]
                if isinstance(zp, str):
                    zo_lengths[len(zp)] += 1
                    for ch in set(zp):
                        zo_chars[ch] += 1
                hn = pa["hatsuon"]
                if isinstance(hn, str):
                    if "<" in hn or ">" in hn:
                        hatsuon_angle += 1
                    else:
                        hatsuon_no_angle += 1
            elif isinstance(pa, list):
                if pa:
                    pitch_is_list_nonempty += 1
            elif pa is not None:
                fail(f"entry {w.get('id')}: kana pitchAccent unexpected type {type(pa).__name__}")
            t = obj.get("text")
            if t in spot and len(spot[t]) < SPOT_MAX:
                spot[t].append(w)

        for s in w.get("sense") or []:
            sense_count += 1
            for key in SENSE_KEYS:
                if key not in s:
                    sense_key_missing[key] += 1
            ak = s.get("appliesToKanji")
            if ak == ["*"]:
                applies_kanji_star += 1
            elif isinstance(ak, list):
                if not ak:
                    applies_kanji_empty += 1
                else:
                    applies_kanji_restricted += 1
            aa = s.get("appliesToKana")
            if aa == ["*"]:
                applies_kana_star += 1
            elif isinstance(aa, list):
                if not aa:
                    applies_kana_empty += 1
                else:
                    applies_kana_restricted += 1
            for g in s.get("gloss") or []:
                gloss_count += 1
                for key in GLOSS_KEYS:
                    if key not in g:
                        gloss_key_missing[key] += 1
                gloss_langs[g.get("lang")] += 1

        if entry_has_jlpt:
            jlpt_entries += 1
        if entry_has_pitch:
            pitch_entries += 1

    out()
    out("=== REQUIRED FIELD INVENTORY ===")
    out(f"word keys missing: {dict(word_key_missing) or 'none'}")
    out(f"kanji keys missing: {dict(kanji_key_missing) or 'none'}")
    out(f"kana keys missing: {dict(kana_key_missing) or 'none'}")
    out(f"sense keys missing: {dict(sense_key_missing) or 'none'}")
    out(f"gloss keys missing: {dict(gloss_key_missing) or 'none'}")
    out()
    out("=== EXTENDED FIELD SHAPES ===")
    out(f"furigana objects (kanji[]): {furigana_count}, malformed: {furigana_bad}, "
        f"without rt: {furigana_no_rt}")
    out(f"pitchAccent dicts: {pitch_obj_count}, non-empty LISTS: {pitch_is_list_nonempty}")
    out(f"hatsuon with <> markers: {hatsuon_angle}, without: {hatsuon_no_angle}")
    out(f"zoPatts alphabet: {dict(zo_chars)}")
    out(f"zoPatts lengths: {dict(sorted(zo_lengths.items()))}")
    out()
    out("=== accPatts VALUE DOMAIN ===")
    for value, count in acc_patts_domain.most_common(40):
        out(f"  {value!r}: {count}")
    out(f"  distinct accPatts values: {len(acc_patts_domain)}")
    out()
    out("=== SPOT CHECKS (kana-text match) ===")
    for key, words in spot.items():
        out(f"-- {key} ({len(words)} shown) --")
        for w in words:
            kebs = [k.get("text") for k in w.get("kanji") or []]
            pitches = [(o.get("text"), (o.get("pitchAccent") or {}).get("accPatts"),
                        (o.get("pitchAccent") or {}).get("zoPatts"),
                        (o.get("pitchAccent") or {}).get("hatsuon"))
                       for o in w.get("kana") or []]
            out(f"  id={w.get('id')} keb={kebs} kana_pitch={pitches}")
    out()
    out("=== JLPT DOMAIN ===")
    for value, count in sorted(jlpt_domain.items(), key=lambda kv: str(kv[0])):
        out(f"  {value!r}: {count}")
    out()
    out("=== STATS ===")
    total = entries or 1
    out(f"entries: {entries}")
    out(f"headword rows (kanji[]+kana[] objects): {headword_count} "
        f"(kanji {kanji_obj_count}, kana {kana_obj_count})")
    out(f"kanji-bearing entries: {kanji_entries} ({kanji_entries/total:.1%}), "
        f"kana-only: {kana_only_entries} ({kana_only_entries/total:.1%})")
    out(f"max kanji[] length: {max_kanji[0]} (entry {max_kanji[1]}), "
        f"max kana[] length: {max_kana[0]} (entry {max_kana[1]})")
    out(f"common=true: kanji objs {kanji_common_true}, kana objs {kana_common_true} "
        f"(kana-only entries with common kana: {kana_only_common_true})")
    out(f"jlpt coverage (entries with >=1 non-null): {jlpt_entries} ({jlpt_entries/total:.1%})")
    out(f"pitch coverage (entries with >=1 dict pitchAccent): {pitch_entries} ({pitch_entries/total:.1%})")
    out(f"senses: {sense_count} (appliesToKanji *= {applies_kanji_star}, "
        f"restricted {applies_kanji_restricted}, empty {applies_kanji_empty}; "
        f"appliesToKana *= {applies_kana_star}, restricted {applies_kana_restricted}, "
        f"empty {applies_kana_empty})")
    out(f"glosses: {gloss_count}, langs: {dict(gloss_langs.most_common(10))}")
    out()
    if id_parse_failures:
        fail(f"{id_parse_failures} ids failed to parse as int")
    if word_key_missing:
        fail(f"words missing required keys: {dict(word_key_missing)}")
    if kanji_key_missing:
        fail(f"kanji objects missing required keys: {dict(kanji_key_missing)}")
    if kana_key_missing:
        fail(f"kana objects missing required keys: {dict(kana_key_missing)}")
    if sense_key_missing:
        fail(f"senses missing required keys: {dict(sense_key_missing)}")
    if gloss_key_missing:
        fail(f"glosses missing required keys: {dict(gloss_key_missing)}")
    if furigana_bad:
        fail(f"{furigana_bad} malformed furigana objects (expected shape {{'ruby', 'rt'?}})")
    if pitch_is_list_nonempty:
        fail(f"{pitch_is_list_nonempty} non-empty pitchAccent lists "
             f"(expected {{hatsuon,accPatts,zoPatts}} or [])")
    non_eng = {k: v for k, v in gloss_langs.items() if k != "eng"}
    if non_eng:
        fail(f"non-eng glosses present (lang filter must stay): {non_eng}")
    if errors:
        out(f"RESULT: FAIL ({len(errors)} problems)")
        out("")
        for e in errors[:50]:
            out(f"  - {e}")
        log.close()
        print(f"PROBE FAILED: {len(errors)} contract violations (see {log_path})")
        for e in errors[:20]:
            print(f"  - {e}")
        sys.exit(1)
    else:
        out("RESULT: PASS")
        log.close()
        print(f"    entries: {entries}  headwords: {headword_count}  senses: {sense_count}")
        print(f"    kana-only: {kana_only_entries/total:.1%}  jlpt: {jlpt_entries/total:.1%}  "
              f"pitch: {pitch_entries/total:.1%}")
        print(f"    accPatts distinct: {len(acc_patts_domain)}  jlpt values: "
              f"{sorted(jlpt_domain, key=str)}  gloss langs: {list(gloss_langs)}")
        print("    PASS")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: jmdict_probe.py <json_path> <log_path>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
