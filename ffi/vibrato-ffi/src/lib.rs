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
mod tests;
