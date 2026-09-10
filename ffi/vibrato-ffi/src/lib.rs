//! C ABI for Mimi's dictionary tokenizer.
//!
//! Wraps the vendored vibrato engine (`vendor/vibrato`, Apache-2.0 OR MIT)
//! behind five generic `dictionary_*` exports. This crate owns the entire FFI
//! surface, so the vendored engine is never patched upstream. The staged
//! artifact is `local/frameworks/libdictionary.dylib`, built and signed by
//! `scripts/build_dictionary.sh`.
//!
//! # Contract
//!
//! - `dictionary_tokenize_json` emits
//!   `[{"text", "start", "end", "reading", "base", "pos"}]`.
//!   `start`/`end` are Unicode-scalar indices into the **original** input,
//!   end-exclusive: vibrato performs no normalization, and its
//!   `Token::range_char()` counts exactly those scalars. Whitespace runs are
//!   left uncovered (MeCab-compatible `ignore_space`), so scalar indices may
//!   skip ahead but never shift.
//! - `reading` is the token's own reading in hiragana; `null` for
//!   unknown/unreadable tokens (`*`, missing column, or empty). The feature
//!   column comes from the lexicon scheme ([`FeatureScheme`]): IPADIC index 7
//!   (katakana), UniDic index 9 (読み — per-surface, katakana/kana mix).
//!   UniDic's pronunciation-style `ー` is expanded to the vowel it prolongs
//!   (学生 → がくせい, not がくせー) unless the surface itself carries `ー`.
//! - `base` is the dictionary form: IPADIC 基本形 (index 6) or the UniDic
//!   lemma 語彙素 (index 7 — 行っ → 行く, 駄洒落 for ダジャレ); `null` for
//!   `*`, missing column, or empty (unknown/short rows).
//! - `pos` is the coarse part-of-speech (feature index 0 in both schemes),
//!   with UniDic tags folded onto their IPADIC counterparts (補助記号 →
//!   記号, 接頭辞 → 接頭詞; see [`FeatureScheme`]); `null` for `*`, missing
//!   column, or empty.
//! - All functions are fail-soft: failures return null/1 rather than panicking.
//! - Calls on one handle must be externally serialized (the Swift engine
//!   holds a lock around FFI calls).

use std::ffi::{c_char, CStr, CString};
use std::fs::File;
use std::io::BufReader;
use std::ops::Range;
use std::path::Path;
use std::ptr;

use serde::Serialize;
use vibrato::{Dictionary, Tokenizer};

/// The lexicon's feature-CSV layout. MeCab-era dictionaries share the payload
/// semantics (reading / base form / coarse POS) but put them in different
/// columns, and the compiled `.dic` carries no metadata (only a vibrato magic
/// header — `model.conf` never reaches the binary), so the scheme is detected
/// at open time from the lexicon rows themselves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FeatureScheme {
    /// IPADIC layout — known rows carry 9 columns:
    /// 品詞×4, 活用型, 活用形, 基本形, 読み, 発音.
    Ipadic,
    /// UniDic layout (unidic-mecab and CWJ share the first columns; CWJ rows
    /// carry extra tail fields) — 品詞×4, 活用型, 活用形, 語彙素読み, 語彙素,
    /// 書字形, 読み, 書字形基本形, 発音, 語種, …:
    ///
    /// - 読み (index 9) is the **per-surface** reading — 行っ → イッ — the
    ///   column furigana alignment needs. The lemma's own reading (語彙素読み,
    ///   index 6: 行っ → イク) must not be used.
    /// - 語彙素 (index 7) is the lemma: the base-form analog (行っ → 行く).
    Unidic,
}

impl FeatureScheme {
    /// Reading column, 0-based. Both schemes store readings in kana; the
    /// payload folds them to hiragana.
    fn reading_column(self) -> usize {
        match self {
            Self::Ipadic => 7,
            Self::Unidic => 9,
        }
    }

    /// Base-form / lemma column, 0-based.
    fn base_column(self) -> usize {
        match self {
            Self::Ipadic => 6,
            Self::Unidic => 7,
        }
    }

    /// Coarse part-of-speech column, 0-based (品詞 in both schemes).
    fn pos_column(self) -> usize {
        0
    }

    /// Maps a UniDic coarse POS tag onto its IPADIC counterpart. Tags beyond
    /// these have identical names in both schemes (名詞, 動詞, 助詞, …).
    /// 接尾辞 has no IPADIC POS1 counterpart (IPADIC tags suffixes 名詞,接尾)
    /// and passes through unchanged — the payload stays descriptive rather
    /// than lossy.
    fn remap_pos(self, pos: &str) -> String {
        match self {
            Self::Ipadic => pos.to_owned(),
            Self::Unidic => match pos {
                "補助記号" => "記号".into(),
                "接頭辞" => "接頭詞".into(),
                _ => pos.into(),
            },
        }
    }
}

/// The marker the lexicon uses for "no value".
const NO_FEATURE: &str = "*";

/// Smallest feature-row shape that identifies a UniDic lexicon. unidic-mecab
/// rows are uniformly 17 columns (known and unknown alike); CWJ rows are
/// longer (29+). IPADIC rows never exceed 9, JUMAN's are 7 — anything else
/// falls back to the IPADIC map, the pre-remap behavior.
const UNIDIC_MIN_FEATURE_COLUMNS: usize = 17;

/// The probe sentence for scheme detection. 行った。 is a known full lexicon
/// row in every MeCab-era dictionary, and its rows have the distinguishing
/// shape (IPADIC 9 columns vs UniDic 17+).
const SCHEME_PROBE: &str = "行った。";

/// Detects the lexicon scheme by probing the tokenizer: the probe's rows are
/// full lexicon entries, and their column count separates UniDic (17+) from
/// everything else. Defaults to IPADIC when the probe yields no tokens or
/// unrecognized shapes — the pre-remap behavior.
fn detect_scheme(tokenizer: &Tokenizer) -> FeatureScheme {
    let mut worker = tokenizer.new_worker();
    worker.reset_sentence(SCHEME_PROBE);
    worker.tokenize();
    let unidic = worker
        .token_iter()
        .any(|token| parse_csv_row(token.feature()).len() >= UNIDIC_MIN_FEATURE_COLUMNS);
    if unidic {
        FeatureScheme::Unidic
    } else {
        FeatureScheme::Ipadic
    }
}

/// Opaque handle created by [`dictionary_open`] and freed by
/// [`dictionary_free`]. Owns the tokenizers' engine and the detected lexicon
/// scheme; workers are created per tokenize call.
pub struct DictionaryHandle {
    tokenizer: Tokenizer,
    scheme: FeatureScheme,
}

/// One entry of the JSON payload; field order is part of the Swift contract.
#[derive(Serialize)]
struct TokenJson {
    text: String,
    start: usize,
    end: usize,
    reading: Option<String>,
    base: Option<String>,
    pos: Option<String>,
}

/// Converts katakana to hiragana per scalar. The ア..ん block shifts down by
/// `0x60` (small kana included); ヴ/ヵ/ヶ have dedicated hiragana counterparts;
/// everything else (ー, ・, non-katakana) passes through unchanged.
fn katakana_to_hiragana(value: &str) -> String {
    value
        .chars()
        .map(|c| match c as u32 {
            0x30A1..=0x30F3 => char::from_u32(c as u32 - 0x60).unwrap_or(c),
            0x30F4 => 'ゔ',
            0x30F5 => 'ゕ',
            0x30F6 => 'ゖ',
            _ => c,
        })
        .collect()
}

/// Expands pronunciation-style `ー` in a reading to the kana vowel it
/// prolongs: しー → しい, こー → こう, てー → てい, with the ambiguous e/o
/// rows taking their canonical spellings (えー → えい, おー → おう). Gated
/// on `surface`: expansion applies only when the surface carries no `ー` of
/// its own — katakana loans legitimately carry it on both sides
/// (ゲーム/げーむ) and must not be touched. A `ー` with nowhere to walk
/// (word-initial, after ン or non-kana) passes through and keeps failing
/// alignment as before, where the annotator's whole-surface fallback covers
/// it.
fn expand_prolonged_marks(reading: &str, surface: &str) -> String {
    if surface.contains('ー') {
        return reading.to_owned();
    }
    let mut expanded = String::with_capacity(reading.len());
    let mut previous = None;
    for c in reading.chars() {
        match previous.and_then(prolonged_vowel) {
            Some(vowel) if c == 'ー' => {
                expanded.push(vowel);
                previous = Some(vowel);
            }
            _ => {
                expanded.push(c);
                previous = Some(c);
            }
        }
    }
    expanded
}

/// The kana vowel a trailing `ー` stands in for, in `kana`'s own script:
/// し → い, こ → う, て → い — the vowel of the kana itself, with the
/// e-row and o-row long vowels folded onto their canonical えい/おう
/// spellings. None for kana without a vowel row (ン) and non-kana.
fn prolonged_vowel(kana: char) -> Option<char> {
    let h = match kana as u32 {
        c @ 0x3041..=0x3096 => c,        // hiragana ぁ..ゖ
        c @ 0x30A1..=0x30F6 => c - 0x60, // katakana ァ..ヶ → hiragana
        _ => return None,
    } as usize;
    // Position on the a-i-u-e-o series, small-kana variants included.
    let row = match h {
        0x3041..=0x304A => (h - 0x3041) / 2, // ぁ..お (small/full pairs)
        0x304B..=0x3054 => (h - 0x304B) / 2, // か..ご
        0x3055..=0x305E => (h - 0x3055) / 2, // さ..ぞ
        // た..ど is 15 kana with pairs 1-off from づ on (づ で ど stray),
        // so the pair arithmetic the other arms use misrows — spelled out.
        0x305F | 0x3060 => 0,    // た だ
        0x3061 | 0x3062 => 1,    // ち ぢ
        0x3063..=0x3065 => 2,    // つ っ づ
        0x3066 | 0x3067 => 3,    // て で
        0x3068 | 0x3069 => 4,    // と ど
        0x306A..=0x306E => h - 0x306A,       // な..の
        0x306F..=0x307D => (h - 0x306F) / 3, // は..ぽ
        0x307E..=0x3082 => h - 0x307E,       // ま..も
        0x3083..=0x3088 => match h {         // ゃゅょやゆよ
            0x3083 | 0x3084 => 0,
            0x3085 | 0x3086 => 2,
            _ => 4,
        },
        0x3089..=0x308D => h - 0x3089, // ら..ろ
        0x308E | 0x308F => 0,          // ゎ わ
        0x3090 => 1,                   // ゐ
        0x3091 => 3,                   // ゑ
        0x3092 => 4,                   // を
        0x3094 => 2,                   // ゔ
        0x3095 => 0,                   // ゕ
        0x3096 => 3,                   // ゖ
        _ => return None,              // ん and stray scalars
    };
    let vowels = if (0x30A1..=0x30F6).contains(&(kana as u32)) {
        ['ア', 'イ', 'ウ', 'イ', 'ウ']
    } else {
        ['あ', 'い', 'う', 'い', 'う']
    };
    vowels.get(row).copied()
}

/// Extracts a feature column verbatim: present only when the column exists
/// and is neither the no-value marker nor empty.
fn feature_column(features: &[String], index: usize) -> Option<String> {
    match features.get(index) {
        Some(raw) if !raw.is_empty() && raw != NO_FEATURE => Some(raw.clone()),
        _ => None,
    }
}

/// Extracts the reading from a parsed feature row under the row's lexicon
/// scheme: present only when the row carries a reading column with something
/// other than `*` or empty, converted to hiragana. UniDic readings are
/// pronunciation-style (ガクセー), so their `ー` is expanded to its source
/// vowel before the fold — surface-gated, per [`expand_prolonged_marks`].
fn reading_from_features(
    features: &[String],
    scheme: FeatureScheme,
    surface: &str,
) -> Option<String> {
    let raw = feature_column(features, scheme.reading_column())?;
    let reading = match scheme {
        FeatureScheme::Ipadic => raw,
        FeatureScheme::Unidic => expand_prolonged_marks(&raw, surface),
    };
    Some(katakana_to_hiragana(&reading))
}

/// Extracts the base form (IPADIC 基本形 / UniDic 語彙素) from a parsed
/// feature row: present only when the row carries a base column with
/// something other than `*` or empty.
fn base_from_features(features: &[String], scheme: FeatureScheme) -> Option<String> {
    feature_column(features, scheme.base_column())
}

/// Extracts the coarse part-of-speech from a parsed feature row: present only
/// when the row carries a first column with something other than `*` or
/// empty, remapped onto the IPADIC tag names.
fn pos_from_features(features: &[String], scheme: FeatureScheme) -> Option<String> {
    feature_column(features, scheme.pos_column()).map(|raw| scheme.remap_pos(&raw))
}

/// Splits a MeCab feature CSV row into columns, honoring double-quoted
/// fields. Mirrors vibrato's private `parse_csv_row`; a single field larger
/// than the buffer degrades to a truncated column instead of panicking.
fn parse_csv_row(row: &str) -> Vec<String> {
    let mut columns = Vec::new();
    let mut reader = csv_core::Reader::new();
    let mut bytes = row.as_bytes();
    let mut output = [0u8; 4096];
    loop {
        let (result, read, written) = reader.read_field(bytes, &mut output);
        let end = match result {
            csv_core::ReadFieldResult::InputEmpty => true,
            csv_core::ReadFieldResult::Field { .. } => false,
            csv_core::ReadFieldResult::End => true,
            _ => true,
        };
        columns.push(String::from_utf8_lossy(&output[..written]).into_owned());
        if end {
            break;
        }
        bytes = &bytes[read..];
    }
    columns
}

/// Builds one payload entry. `scalar_range` is the token's span in
/// Unicode-scalar indices (vibrato's `Token::range_char()`); `surface` is the
/// verbatim input slice.
fn token_payload(
    surface: String,
    scalar_range: Range<usize>,
    features: &[String],
    scheme: FeatureScheme,
) -> TokenJson {
    let reading = reading_from_features(features, scheme, &surface);
    TokenJson {
        text: surface,
        start: scalar_range.start,
        end: scalar_range.end,
        reading,
        base: base_from_features(features, scheme),
        pos: pos_from_features(features, scheme),
    }
}

/// Serializes the payload; infallible in practice (no interior NULs, plain
/// scalars), with an empty-array fallback so the FFI never emits garbage.
fn serialize_tokens(tokens: &[TokenJson]) -> String {
    serde_json::to_string(tokens).unwrap_or_else(|_| "[]".to_string())
}

impl DictionaryHandle {
    fn tokenize_json(&self, input: &str) -> String {
        let mut worker = self.tokenizer.new_worker();
        worker.reset_sentence(input);
        worker.tokenize();
        let mut tokens = Vec::with_capacity(worker.num_tokens());
        for token in worker.token_iter() {
            let features = parse_csv_row(token.feature());
            tokens.push(token_payload(
                token.surface().to_owned(),
                token.range_char(),
                &features,
                self.scheme,
            ));
        }
        serialize_tokens(&tokens)
    }
}

fn open_dictionary(path: &Path) -> Option<DictionaryHandle> {
    let file = File::open(path).ok()?;
    let dictionary = Dictionary::read(BufReader::new(file)).ok()?;
    let tokenizer = Tokenizer::new(dictionary).ignore_space(true).ok()?;
    let scheme = detect_scheme(&tokenizer);
    Some(DictionaryHandle { tokenizer, scheme })
}

fn prepare_dictionary(zst_path: &Path, out_path: &Path) -> std::io::Result<()> {
    let input = File::open(zst_path)?;
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(input)
        .map_err(|error| std::io::Error::other(format!("zstd frame error: {error:?}")))?;
    // Decompress to a sibling temp file and rename, so a failure never leaves
    // a partial artifact at `out_path` (the Swift store moves the output into
    // place itself; this is defense in depth).
    let part_path = out_path.with_file_name(format!(
        "{}.part",
        out_path.file_name().unwrap_or_default().to_string_lossy()
    ));
    // `io::copy` writes straight through to the file, so write errors
    // propagate; no buffered writer that could swallow a flush failure.
    let result = std::io::copy(&mut decoder, &mut File::create(&part_path)?)
        .and_then(|_| std::fs::rename(&part_path, out_path));
    match result {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = std::fs::remove_file(&part_path);
            Err(error)
        }
    }
}

/// Opens the **decompressed** dictionary at `dic_path` and returns an opaque
/// handle, or null on failure (missing/invalid file, unsupported model).
///
/// # Safety
///
/// `dic_path` must be null or a valid, null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn dictionary_open(dic_path: *const c_char) -> *mut DictionaryHandle {
    if dic_path.is_null() {
        return ptr::null_mut();
    }
    let path = CStr::from_ptr(dic_path).to_string_lossy();
    open_dictionary(Path::new(path.as_ref()))
        .map_or(ptr::null_mut(), |handle| Box::into_raw(Box::new(handle)))
}

/// Frees a handle returned by [`dictionary_open`]; null is a no-op.
///
/// # Safety
///
/// `handle` must be null or a pointer returned by [`dictionary_open`] that
/// has not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn dictionary_free(handle: *mut DictionaryHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Tokenizes `text` into a JSON array
/// `[{text, start, end, reading, base, pos}]` owned by the runtime until
/// released with [`dictionary_free_string`]. Returns
/// null on failure (null arguments, invalid UTF-8, allocation failure).
///
/// # Safety
///
/// `handle` must be null or a live [`dictionary_open`] handle, and `text`
/// must be null or a valid, null-terminated UTF-8 C string. Calls on the
/// same handle must be externally serialized.
#[no_mangle]
pub unsafe extern "C" fn dictionary_tokenize_json(
    handle: *mut DictionaryHandle,
    text: *const c_char,
) -> *mut c_char {
    if handle.is_null() || text.is_null() {
        return ptr::null_mut();
    }
    let input = match CStr::from_ptr(text).to_str() {
        Ok(input) => input,
        Err(_) => return ptr::null_mut(),
    };
    let json = (*handle).tokenize_json(input);
    match CString::new(json) {
        Ok(c_json) => c_json.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Frees a string returned by [`dictionary_tokenize_json`]; null is a no-op.
///
/// # Safety
///
/// `s` must be null or a pointer returned by [`dictionary_tokenize_json`]
/// that has not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn dictionary_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Decompresses the bundled `system.dic.zst` at `zst_path` to `out_path`
/// (the one-time first-launch step; the output feeds [`dictionary_open`]).
/// Returns 0 on success, 1 on failure (missing input, bad zstd, I/O error);
/// never leaves a partial output file.
///
/// # Safety
///
/// Both arguments must be null or valid, null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn dictionary_prepare(
    zst_path: *const c_char,
    out_path: *const c_char,
) -> i32 {
    let zst = (!zst_path.is_null()).then(|| CStr::from_ptr(zst_path).to_string_lossy());
    let out = (!out_path.is_null()).then(|| CStr::from_ptr(out_path).to_string_lossy());
    let result = zst
        .zip(out)
        .map(|(zst, out)| prepare_dictionary(Path::new(zst.as_ref()), Path::new(out.as_ref())));
    match result {
        Some(Ok(())) => 0,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The scalar-slice helper the tests use to mirror the FFI's surface
    /// construction (the live path slices bytes via `Token::surface()`; the
    /// helper walks scalars, and both agree because vibrato does no
    /// normalization — the model-gated integration test pins that end to end).
    fn scalar_slice(input: &str, range: Range<usize>) -> String {
        input.chars().skip(range.start).take(range.len()).collect()
    }

    #[test]
    fn kata_to_hira_basic_block() {
        assert_eq!(katakana_to_hiragana("ワタシ"), "わたし");
        assert_eq!(katakana_to_hiragana("ガクセイ"), "がくせい");
        // Small kana sit inside the shifted block.
        assert_eq!(katakana_to_hiragana("ラーメンッャ"), "らーめんっゃ");
        assert_eq!(katakana_to_hiragana(""), "");
    }

    #[test]
    fn kata_to_hira_vu_class() {
        // ヴ has a dedicated hiragana counterpart; the following small vowel
        // is shifted by the plain block rule.
        assert_eq!(katakana_to_hiragana("ヴァ"), "ゔぁ");
        assert_eq!(katakana_to_hiragana("ヴ"), "ゔ");
    }

    #[test]
    fn kata_to_hira_obsolete_kana() {
        assert_eq!(katakana_to_hiragana("ヰヱ"), "ゐゑ");
    }

    #[test]
    fn kata_to_hira_small_ka_ke() {
        assert_eq!(katakana_to_hiragana("ヵヶ"), "ゕゖ");
    }

    #[test]
    fn kata_to_hira_prolonged_mark_passes_through() {
        // ー (U+30FC) is outside the shifted block.
        assert_eq!(katakana_to_hiragana("ガッコー"), "がっこー");
        assert_eq!(katakana_to_hiragana("ー"), "ー");
    }

    #[test]
    fn kata_to_hira_non_katakana_passes_through() {
        assert_eq!(katakana_to_hiragana("漢字abc123"), "漢字abc123");
        assert_eq!(katakana_to_hiragana("ひらがな"), "ひらがな");
    }

    #[test]
    fn reading_uses_eighth_column_and_converts() {
        let row = parse_csv_row("名詞,一般,*,*,*,*,本,ホン,ホン");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Ipadic, "本").as_deref(),
            Some("ほん")
        );
        // Conjugated surfaces carry their own readings — the migration's
        // whole reason.
        let row = parse_csv_row("動詞,自立,*,*,一段,基本形,見る,ミ,ミ");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Ipadic, "見る").as_deref(),
            Some("み")
        );
        let row = parse_csv_row("動詞,自立,*,*,一段,基本形,食べる,タベ,タベ");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Ipadic, "食べる").as_deref(),
            Some("たべ")
        );
        let row = parse_csv_row("動詞,自立,*,*,五段,タ形,言う,イッ,イッ");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Ipadic, "言っ").as_deref(),
            Some("いっ")
        );
    }

    #[test]
    fn reading_missing_for_unknown_shape() {
        // Unknown tokens carry only 7 columns; index 7 is absent.
        let row = parse_csv_row("名詞,固有名詞,組織,*,*,*,*");
        assert_eq!(reading_from_features(&row, FeatureScheme::Ipadic, "ミミ"), None);
        assert_eq!(reading_from_features(&[], FeatureScheme::Ipadic, "ミミ"), None);
    }

    #[test]
    fn base_uses_seventh_column() {
        // Conjugated surfaces carry their dictionary base form.
        let row = parse_csv_row("動詞,自立,*,*,五段,タ形,言う,イッ,イッ");
        assert_eq!(
            base_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("言う")
        );
        let row = parse_csv_row("動詞,自立,*,*,一段,基本形,見る,ミ,ミ");
        assert_eq!(
            base_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("見る")
        );
        // Kana-only surfaces carry their own base form.
        let row = parse_csv_row("助詞,係助詞,*,*,*,*,は,ハ,ワ");
        assert_eq!(
            base_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("は")
        );
    }

    #[test]
    fn base_missing_for_unknown_shape() {
        // Short (unknown) row: no base column at all.
        let row = parse_csv_row("名詞,固有名詞,組織,*,*,*,*");
        assert_eq!(base_from_features(&row, FeatureScheme::Ipadic), None);
        assert_eq!(base_from_features(&[], FeatureScheme::Ipadic), None);
        // Full-length rows with a `*` or empty base.
        let row = parse_csv_row("名詞,数,*,*,*,*,*,*,*");
        assert_eq!(base_from_features(&row, FeatureScheme::Ipadic), None);
        let row = parse_csv_row("名詞,一般,*,*,*,*,*,");
        assert_eq!(base_from_features(&row, FeatureScheme::Ipadic), None);
    }

    #[test]
    fn pos_uses_first_column() {
        let row = parse_csv_row("名詞,一般,*,*,*,*,本,ホン,ホン");
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("名詞")
        );
        let row = parse_csv_row("動詞,自立,*,*,五段,タ形,言う,イッ,イッ");
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("動詞")
        );
    }

    #[test]
    fn pos_missing_for_star_or_empty() {
        let row = parse_csv_row("*,*,*,*,*,*,*,*,*");
        assert_eq!(pos_from_features(&row, FeatureScheme::Ipadic), None);
        let row = parse_csv_row(",一般,*,*,*,*,*,");
        assert_eq!(pos_from_features(&row, FeatureScheme::Ipadic), None);
        assert_eq!(pos_from_features(&[], FeatureScheme::Ipadic), None);
    }

    #[test]
    fn reading_missing_for_star_or_empty() {
        // 9-column shape with a `*` reading.
        let row = parse_csv_row("名詞,数,*,*,*,*,*,*,*");
        assert_eq!(reading_from_features(&row, FeatureScheme::Ipadic, "ぼ"), None);
        // 8-column shape with an empty reading.
        let row = parse_csv_row("名詞,一般,*,*,*,*,*,");
        assert_eq!(reading_from_features(&row, FeatureScheme::Ipadic, "ぼ"), None);
    }

    // Real UniDic feature rows (probed from unidic-mecab-2_1_2 / CWJ; both
    // share the first 17 columns).

    #[test]
    fn unidic_reading_uses_per_surface_kana_column() {
        // 読み (index 9) is the surface's own reading — the IPADIC 読み
        // analog. The lemma's reading (語彙素読み, index 6) must never leak:
        // 行っ reads いっ, not いく.
        let row = parse_csv_row(
            "動詞,非自立可能,*,*,五段-カ行,連用形-促音便,イク,行く,行っ,イッ,行く,イク,和,*,*,*,*",
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "行っ").as_deref(),
            Some("いっ")
        );
        // Long-vowel style readings expand to their source vowel before the
        // fold: がくせー reads がくせい, matching the surface for alignment.
        let row = parse_csv_row(
            "名詞,普通名詞,一般,*,*,*,ガクセイ,学生,学生,ガクセー,学生,ガクセー,漢,*,*,*,*",
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "学生").as_deref(),
            Some("がくせい")
        );
        // Function words are listed by pronunciation.
        let row = parse_csv_row("助詞,係助詞,*,*,*,*,ハ,は,は,ワ,は,ワ,和,*,*,*,*");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "は").as_deref(),
            Some("わ")
        );
        // Hiragana readings pass the fold unchanged.
        let row = parse_csv_row(
            "助動詞,*,*,*,助動詞-ナイ,連用形-促音便,ナイ,ない,なかっ,ナカッ,ない,ナイ,和,*,*,*,*",
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "なかっ").as_deref(),
            Some("なかっ")
        );
    }

    #[test]
    fn unidic_reading_expands_pronunciation_style_prolonged_marks() {
        // Every vowel row walks to its source vowel, in the reading's own
        // script; the ambiguous e/o rows take their canonical spellings
        // (えい/おう).
        let cases = [
            ("ガクセー", "ガクセイ"),
            ("シークレット", "シイクレット"),
            ("イコー", "イコウ"),
            ("テスト", "テスト"),
            ("エー", "エイ"),
            ("オー", "オウ"),
            ("カー", "カア"),
            ("やー", "やあ"),
            ("むずかしー", "むずかしい"),
        ];
        for (reading, expanded) in cases {
            assert_eq!(expand_prolonged_marks(reading, "漢字"), expanded);
        }
        // Surfaces carrying their own ー stay untouched — katakana loans
        // carry it on both sides legitimately.
        assert_eq!(expand_prolonged_marks("ゲーム", "ゲーム"), "ゲーム");
        assert_eq!(expand_prolonged_marks("わーい", "わーい"), "わーい");
        // A ー with no vowel to walk to passes through (the annotator's
        // whole-surface fallback covers the alignment failure).
        assert_eq!(expand_prolonged_marks("ー", "漢字"), "ー");
        assert_eq!(expand_prolonged_marks("ンー", "漢字"), "ンー");
        assert_eq!(expand_prolonged_marks("Aー", "漢字"), "Aー");
        // The expansion travels through the payload end to end — the
        // corpus's dominant failure shape: 難し/ムズカシー.
        let row = parse_csv_row(
            "形容詞,非自立可能,*,*,形容詞,連用形-一般,ムズカシイ,難しい,難し,ムズカシー,難しい,ムズカシイ,和,*,*,*,*",
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "難し").as_deref(),
            Some("むずかしい")
        );
    }

    #[test]
    fn ipadic_reading_keeps_prolonged_marks() {
        // IPADIC readings already use dictionary-style kana; the expansion
        // is UniDic-only so the baseline output stays byte-identical.
        let row = parse_csv_row("名詞,一般,*,*,*,*,ゲーム,ゲーム,ゲーム");
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Ipadic, "ゲーム").as_deref(),
            Some("げーむ")
        );
    }

    #[test]
    fn prolonged_vowel_dakuten_rows() {
        // The た..ど run rows, voiced included: plain/dakuten pairs share a
        // row, and the stray kana sit where their vowel says.
        let cases = [
            ('た', 'あ'),
            ('だ', 'あ'),
            ('ち', 'い'),
            ('ぢ', 'い'),
            ('つ', 'う'),
            ('っ', 'う'),
            ('づ', 'う'),
            ('て', 'い'),
            ('で', 'い'),
            ('と', 'う'),
            ('ど', 'う'),
            ('ド', 'ウ'),
        ];
        for (kana, vowel) in cases {
            assert_eq!(prolonged_vowel(kana), Some(vowel), "kana {kana}");
        }
    }

    #[test]
    fn expand_prolonged_marks_dakuten_readings() {
        // どー → どう (the corpus's dominant shape), and the latent rows.
        let cases = [
            ("ドー", "ドウ"),
            ("どー", "どう"),
            ("でー", "でい"),
            ("ヅー", "ヅウ"),
            ("ドーブツ", "ドウブツ"),
            ("かんどー", "かんどう"),
        ];
        for (reading, expanded) in cases {
            assert_eq!(expand_prolonged_marks(reading, "漢字"), expanded);
        }
    }

    #[test]
    fn unidic_dakuten_prolonged_reading_expands_end_to_end() {
        // 動物's UniDic row: pron ドーブツ expands to ドウブツ before the
        // fold, so the payload reading is どうぶつ — the surface gate still
        // holds when the word itself carries ー (expansion skipped, ー
        // passes through, same as ゲーム/げーむ).
        let row = parse_csv_row(
            "名詞,普通名詞,一般,*,*,*,ドウブツ,動物,動物,ドーブツ,動物,ドーブツ,漢,*,*,*,*",
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "動物").as_deref(),
            Some("どうぶつ")
        );
        assert_eq!(
            reading_from_features(&row, FeatureScheme::Unidic, "動物ー").as_deref(),
            Some("どーぶつ")
        );
    }

    #[test]
    fn unidic_reading_missing_when_kana_column_empty() {
        // Punctuation carries no 読み; index 6 holds an empty field, not `*`.
        let row = parse_csv_row("補助記号,句点,*,*,*,*,,。,。,,。,,記号,*,*,*,*");
        assert_eq!(reading_from_features(&row, FeatureScheme::Unidic, "。"), None);
        assert_eq!(
            base_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("。")
        );
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("記号")
        );
    }

    #[test]
    fn unidic_base_uses_lemma_column() {
        let row = parse_csv_row(
            "動詞,非自立可能,*,*,五段-カ行,連用形-促音便,イク,行く,行っ,イッ,行く,イク,和,*,*,*,*",
        );
        assert_eq!(
            base_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("行く")
        );
        // Katakana words lemmatize to their written (often kanji) form.
        let row = parse_csv_row("名詞,普通名詞,一般,*,*,*,ダジャレ,駄洒落,ダジャレ,ダジャレ,ダジャレ,ダジャレ,混,*,*,*,*");
        assert_eq!(
            base_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("駄洒落")
        );
        let row = parse_csv_row("助動詞,*,*,*,助動詞-タ,終止形-一般,タ,た,た,タ,た,タ,和,*,*,*,*");
        assert_eq!(
            base_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("た")
        );
    }

    #[test]
    fn unidic_pos_folds_onto_ipadic_tags() {
        let row = parse_csv_row("補助記号,句点,*,*,*,*,,。,。,,。,,記号,*,*,*,*");
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("記号")
        );
        let row = parse_csv_row("接頭辞,名詞接続,*,*,*,*,ゼン,前,前,ゼン,前,ゼン,漢,*,*,*,*");
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("接頭詞")
        );
        // Shared tags and counterpart-less tags pass through.
        let row = parse_csv_row(
            "動詞,非自立可能,*,*,五段-カ行,連用形-促音便,イク,行く,行っ,イッ,行く,イク,和,*,*,*,*",
        );
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("動詞")
        );
        let row = parse_csv_row("接尾辞,名詞的,*,*,*,*,テキ,的,的,テキ,的,テキ,漢,*,*,*,*");
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Unidic).as_deref(),
            Some("接尾辞")
        );
        assert_eq!(
            pos_from_features(&row, FeatureScheme::Ipadic).as_deref(),
            Some("接尾辞")
        );
    }

    #[test]
    fn unidic_payload_matches_swift_contract() {
        // The 行っ row end to end: per-surface reading, lemma base, coarse POS.
        let row = parse_csv_row(
            "動詞,非自立可能,*,*,五段-カ行,連用形-促音便,イク,行く,行っ,イッ,行く,イク,和,*,*,*,*",
        );
        let token = token_payload("行っ".to_owned(), 0..2, &row, FeatureScheme::Unidic);
        assert_eq!(token.reading.as_deref(), Some("いっ"));
        assert_eq!(token.base.as_deref(), Some("行く"));
        assert_eq!(token.pos.as_deref(), Some("動詞"));
    }

    #[test]
    fn unidic_rows_are_recognized_by_column_count() {
        // The detection invariant: known and unknown UniDic rows alike carry
        // ≥ 17 columns, while IPADIC rows never do. These row shapes are the
        // ones `SCHEME_PROBE` ("行った。") produces.
        let unidic_oku = parse_csv_row(
            "動詞,非自立可能,*,*,五段-カ行,連用形-促音便,イク,行く,行っ,イッ,行く,イク,和,*,*,*,*",
        );
        assert!(unidic_oku.len() >= UNIDIC_MIN_FEATURE_COLUMNS);
        let ipadic_oku = parse_csv_row("動詞,自立,*,*,五段・カ行促音便,連用タ接続,行く,イッ,イッ");
        assert!(ipadic_oku.len() < UNIDIC_MIN_FEATURE_COLUMNS);
        let ipadic_unknown = parse_csv_row("名詞,数,*,*,*,*,*");
        assert!(ipadic_unknown.len() < UNIDIC_MIN_FEATURE_COLUMNS);
    }

    #[test]
    fn csv_row_handles_quoted_fields() {
        let row = parse_csv_row(r#"名詞,"a,b",c"#);
        assert_eq!(row, vec!["名詞", "a,b", "c"]);
    }

    #[test]
    fn json_shape_matches_swift_contract() {
        let input = "私は学生です";
        let tokens = [
            ("私", 0..1, "名詞,代名詞,一般,*,*,*,私,ワタシ,ワタシ"),
            ("は", 1..2, "助詞,係助詞,*,*,*,*,は,ハ,ワ"),
            ("学生", 2..4, "名詞,一般,*,*,*,*,学生,ガクセイ,ガクセイ"),
            ("です", 4..6, "助動詞,*,*,*,特殊,デス,です,デス,デス"),
        ]
        .into_iter()
        .map(|(_, range, features)| {
            token_payload(
                scalar_slice(input, range.clone()),
                range,
                &parse_csv_row(features),
                FeatureScheme::Ipadic,
            )
        })
        .collect::<Vec<_>>();
        assert_eq!(
            serialize_tokens(&tokens),
            "[{\"text\":\"私\",\"start\":0,\"end\":1,\"reading\":\"わたし\",\"base\":\"私\",\"pos\":\"名詞\"},\
              {\"text\":\"は\",\"start\":1,\"end\":2,\"reading\":\"は\",\"base\":\"は\",\"pos\":\"助詞\"},\
              {\"text\":\"学生\",\"start\":2,\"end\":4,\"reading\":\"がくせい\",\"base\":\"学生\",\"pos\":\"名詞\"},\
              {\"text\":\"です\",\"start\":4,\"end\":6,\"reading\":\"です\",\"base\":\"です\",\"pos\":\"助動詞\"}]"
        );
    }

    #[test]
    fn json_reading_null_when_unknown() {
        let tokens = [token_payload(
            "😊".to_owned(),
            0..1,
            &parse_csv_row("記号,一般,*,*,*,*,*,*"),
            FeatureScheme::Ipadic,
        )];
        // The symbol row is full-length: base is `*` (null) but the coarse
        // POS is still 記号.
        assert_eq!(
            serialize_tokens(&tokens),
            "[{\"text\":\"😊\",\"start\":0,\"end\":1,\"reading\":null,\"base\":null,\"pos\":\"記号\"}]"
        );
    }

    #[test]
    fn json_base_and_pos_null_for_unknown_shape() {
        // A short unknown row has neither base nor reading columns; only the
        // coarse POS survives.
        let tokens = [token_payload(
            "ミミ".to_owned(),
            0..2,
            &parse_csv_row("名詞,固有名詞,一般,*,*,*,*"),
            FeatureScheme::Ipadic,
        )];
        assert_eq!(
            serialize_tokens(&tokens),
            "[{\"text\":\"ミミ\",\"start\":0,\"end\":2,\"reading\":null,\"base\":null,\"pos\":\"名詞\"}]"
        );
    }

    #[test]
    fn json_empty_input_yields_empty_array() {
        assert_eq!(serialize_tokens(&[]), "[]");
    }

    #[test]
    fn scalar_spans_over_hazardous_input() {
        // Each of these is exactly one Unicode scalar but 1–4 bytes:
        // SIP kanji, emoji, ASCII, ZWNJ, ASCII.
        let input = "𠮷😊a\u{200C}b";
        assert_eq!(input.chars().count(), 5);
        assert_eq!(scalar_slice(input, 0..1), "𠮷");
        assert_eq!(scalar_slice(input, 1..2), "😊");
        assert_eq!(scalar_slice(input, 2..3), "a");
        assert_eq!(scalar_slice(input, 3..4), "\u{200C}");
        assert_eq!(scalar_slice(input, 4..5), "b");
    }

    #[test]
    fn scalar_spans_skip_uncovered_whitespace() {
        // With ignore_space, the whitespace run stays uncovered; later token
        // indices keep counting the full input's scalars.
        let input = "A  B";
        let tokens = [
            token_payload(scalar_slice(input, 0..1), 0..1, &[], FeatureScheme::Ipadic),
            token_payload(scalar_slice(input, 3..4), 3..4, &[], FeatureScheme::Ipadic),
        ];
        assert_eq!(tokens[0].text, "A");
        assert_eq!(tokens[1].text, "B");
        assert_eq!(tokens[1].start, 3);
    }

    #[test]
    fn payload_spans_and_reading_travel_together() {
        // Multibyte start: indices are scalar-based, not byte-based.
        let input = "動画を見ます。";
        let tokens = [
            token_payload(
                scalar_slice(input, 0..2),
                0..2,
                &parse_csv_row("名詞,一般,*,*,*,*,動画,ドウガ,ドーガ"),
                FeatureScheme::Ipadic,
            ),
            token_payload(
                scalar_slice(input, 2..3),
                2..3,
                &parse_csv_row("助詞,格助詞,一般,*,*,*,を,ヲ,ヲ"),
                FeatureScheme::Ipadic,
            ),
            token_payload(
                scalar_slice(input, 3..4),
                3..4,
                &parse_csv_row("動詞,自立,*,*,一段,基本形,見る,ミ,ミ"),
                FeatureScheme::Ipadic,
            ),
            token_payload(
                scalar_slice(input, 4..6),
                4..6,
                &parse_csv_row("助動詞,*,*,*,特殊,マス,ます,マス,マス"),
                FeatureScheme::Ipadic,
            ),
            token_payload(
                scalar_slice(input, 6..7),
                6..7,
                &parse_csv_row("記号,句点,*,*,*,*,。,。,。"),
                FeatureScheme::Ipadic,
            ),
        ];
        let starts = tokens.iter().map(|t| t.start).collect::<Vec<_>>();
        let ends = tokens.iter().map(|t| t.end).collect::<Vec<_>>();
        assert_eq!(starts, [0, 2, 3, 4, 6]);
        assert_eq!(ends, [2, 3, 4, 6, 7]);
        assert_eq!(tokens[0].reading.as_deref(), Some("どうが"));
        assert_eq!(tokens[1].reading.as_deref(), Some("を"));
    }

    #[test]
    fn prepare_dictionary_rejects_missing_input() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("out.dic");
        let zst = dir.path().join("missing.dic.zst");
        assert!(prepare_dictionary(&zst, &out).is_err());
        assert!(!out.exists());
    }

    #[test]
    fn prepare_dictionary_rejects_bad_zstd_without_partial_file() {
        let dir = tempfile::tempdir().unwrap();
        let zst = dir.path().join("junk.dic.zst");
        std::fs::write(&zst, b"definitely not zstd").unwrap();
        let out = dir.path().join("out.dic");
        assert!(prepare_dictionary(&zst, &out).is_err());
        assert!(!out.exists());
        // No partial artifact beside the output either.
        assert!(dir
            .path()
            .read_dir()
            .unwrap()
            .all(|entry| entry.unwrap().file_name() != "out.dic.part"));
    }
}
