#!/usr/bin/env python3
"""Build the JMDict lookup DB from the pinned JMDict_Extended asset.

Consumes the stream-parsed JSON (already probe-passed by jmdict_probe.py —
the run that emits the probe report must have used this exact file),
writes the SQLite schema, reconciles row counts against the probe report,
and compresses to zstd.

Usage: jmdict_build.py <json_path> <db_path> <zst_path> <probe_log_path>
                       <pin_tag> <pin_sha256> <pin_asset>
"""

import json
import os
import re
import sqlite3
import subprocess
import sys


def main(json_path, db_path, zst_path, probe_log_path, pin_tag, pin_sha256, pin_asset):
    errors = []
    def fail(msg):
        errors.append(msg)

    def out(line=""):
        print(line)

    # --- header ----------------------------------------------------------------
    # BOM stripped by utf-8-sig; header keys precede the "words": [ line. A single
    # file handle: the word stream continues right after the "words" line.
    header = {}
    first = ""
    f = open(json_path, encoding="utf-8-sig")
    for line in f:
        s = line.strip()
        if s.startswith('"words"'):
            first = s.split("[", 1)[1] if "[" in s else ""
            break
        m = re.match(r'"([A-Za-z]+)"\s*:\s*(.*?),?\s*$', s)
        if m:
            header[m.group(1)] = m.group(2).rstrip(",")
        elif s in ("{", "}"):
            continue
        else:
            print(f"ERROR: unrecognized header line: {s[:80]!r}", file=sys.stderr)
            sys.exit(1)

    version = header.get("version", "?").strip('"')
    dict_date = header.get("dictDate", "?").strip('"')

    # --- schema (plan §3 — no FTS, exact headwords.text queries only) ----------
    conn = sqlite3.connect(db_path)
    conn.executescript("""
    PRAGMA journal_mode=OFF;
    PRAGMA synchronous=OFF;
    CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
    CREATE TABLE senses(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
      ord INTEGER NOT NULL, pos TEXT, gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT);
    CREATE TABLE headwords(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
      text TEXT NOT NULL, kind TEXT NOT NULL, jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT);
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    """)

    # One word per line, trailing comma even on the last; the first word sits on
    # the "words": [ line itself. Not valid JSON as a whole — stream it.
    def word_chunks(fobj, first):
        if first.strip():
            yield first
        for raw in fobj:
            s = raw.strip()
            if s in ("]}", "]"):
                return
            if s:
                yield s

    def norm_restricted(lst):
        # "*" = applies to all writings -> NULL; otherwise JSON (empty list =
        # matches none — defensive, upstream never emits it at sense level).
        if lst is None or lst == ["*"]:
            return None
        return json.dumps(lst, ensure_ascii=False)

    def hw_row(ent_seq, obj, kind):
        # Furigana is dropped (IPADIC-based alignment already exists).
        pa = obj.get("pitchAccent")
        if isinstance(pa, dict):
            pitch = (pa.get("hatsuon"), pa.get("accPatts"), pa.get("zoPatts"))
        else:
            pitch = (None, None, None)
        return (ent_seq, obj["text"], kind, obj.get("jlptLevel"), *pitch)

    BATCH = 5000
    entries_batch, senses_batch, headwords_batch = [], [], []
    counts = {"entries": 0, "senses": 0, "headwords": 0}

    def flush():
        if entries_batch:
            conn.executemany("INSERT INTO entries VALUES (?,?,?,?)", entries_batch)
            entries_batch.clear()
        if senses_batch:
            conn.executemany("INSERT INTO senses VALUES (?,?,?,?,?,?,?)", senses_batch)
            senses_batch.clear()
        if headwords_batch:
            conn.executemany("INSERT INTO headwords VALUES (?,?,?,?,?,?,?)", headwords_batch)
            headwords_batch.clear()

    for stripped in word_chunks(f, first):
        if stripped.endswith(","):
            stripped = stripped[:-1]
        try:
            w = json.loads(stripped)
        except Exception as exc:
            fail(f"word JSON failed to parse: {exc}: {stripped[:120]!r}")
            break

        ent_seq = int(w["id"])
        kobjs = w.get("kanji") or []
        robjs = w.get("kana") or []
        common = 1 if any(o.get("common") for o in kobjs) or any(o.get("common") for o in robjs) else 0
        entries_batch.append((
            ent_seq,
            kobjs[0]["text"] if kobjs else None,
            robjs[0]["text"] if robjs else None,
            common,
        ))
        for o in kobjs:
            headwords_batch.append(hw_row(ent_seq, o, "keb"))
        for o in robjs:
            headwords_batch.append(hw_row(ent_seq, o, "reb"))
        for ord_i, s in enumerate(w.get("sense") or []):
            glosses = [g["text"] for g in (s.get("gloss") or []) if g.get("lang") == "eng"]
            senses_batch.append((
                ent_seq,
                ord_i,
                ",".join(s.get("partOfSpeech") or []) or None,
                "; ".join(glosses),
                ", ".join(s.get("misc") or []) or None,
                norm_restricted(s.get("appliesToKanji")),
                norm_restricted(s.get("appliesToKana")),
            ))
        counts["entries"] += 1
        counts["headwords"] += len(kobjs) + len(robjs)
        counts["senses"] += len(w.get("sense") or [])
        if len(entries_batch) >= BATCH:
            flush()

    flush()
    conn.executescript(
        "CREATE INDEX idx_senses_entry ON senses(entry_id);"
        "CREATE INDEX idx_headwords_text ON headwords(text);"
    )

    # --- reconcile against the probe report (same pin, same file) ---------------
    if not os.path.exists(probe_log_path):
        fail(f"probe report missing: {probe_log_path} (run the probe first)")
    else:
        probe = open(probe_log_path, encoding="utf-8").read()
        def probe_count(pattern):
            m = re.search(pattern, probe, re.M)
            if not m:
                fail(f"probe report missing stat {pattern!r}")
                return None
            return int(m.group(1))
        expected = {
            "entries": probe_count(r"^entries: (\d+)$"),
            "headwords": probe_count(r"^headword rows \(kanji\[\]\+kana\[\] objects\): (\d+)"),
            "senses": probe_count(r"^senses: (\d+)"),
        }
        for label, want in expected.items():
            if want is not None and counts[label] != want:
                fail(f"{label} mismatch: DB {counts[label]} vs probe {want}")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # --- meta -------------------------------------------------------------------
    conn.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", [
        ("version", version),
        ("tag", pin_tag),
        ("digest", pin_sha256),
        ("source_asset", pin_asset),
        ("dict_date", dict_date),
        ("entries", str(counts["entries"])),
        ("senses", str(counts["senses"])),
        ("headwords", str(counts["headwords"])),
    ])
    conn.commit()

    def compress():
        subprocess.run(["zstd", "-19", "-f", "-q", "-o", zst_path, db_path], check=True)
        return os.path.getsize(zst_path)

    zst_bytes = compress()
    # Record both sizes, then recompress once so the shipped zst matches the
    # final DB bytes (the recorded values are the pre-close measurements).
    conn.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", [
        ("size.sqlite.bytes", str(os.path.getsize(db_path))),
        ("size.zst.bytes", str(zst_bytes)),
    ])
    conn.commit()
    conn.close()
    compress()

    raw_mb = os.path.getsize(db_path) / (1000 * 1000)
    zst_mb = os.path.getsize(zst_path) / (1000 * 1000)
    out("==> JMDict DB built")
    out(f"    db:      {zst_path} ({zst_mb:.1f} MB; uncompressed {raw_mb:.1f} MB)")
    out(f"    rows:    entries {counts['entries']} / headwords {counts['headwords']} / "
        f"senses {counts['senses']} (reconciled with probe)")
    out(f"    meta:    version={version} dictDate={dict_date} tag={pin_tag}")
    out(f"    DMG delta: ~{zst_mb:.1f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 8:
        print("usage: jmdict_build.py <json_path> <db_path> <zst_path> "
              "<probe_log_path> <pin_tag> <pin_sha256> <pin_asset>", file=sys.stderr)
        sys.exit(2)
    main(*sys.argv[1:8])
