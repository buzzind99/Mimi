//! Integration test against a real UniDic model — gated on the eval artifact
//! `scripts/eval_dictionary.sh` fetches into
//! `local/dictionaries/eval/unidic-mecab-2_1_2/`. Pins the UniDic
//! feature-column remap end to end: per-surface readings (not lemmas), lemma
//! base forms, IPADIC-folded POS, and the scheme auto-detection at open.
//! Skips visibly (with a hint) when the model is absent, so `cargo test`
//! stays green on a fresh clone before the fetch.

use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

use serde_json::Value;

use vibrato_ffi::{
    dictionary_free, dictionary_free_string, dictionary_open, dictionary_prepare,
    dictionary_tokenize_json, DictionaryHandle,
};

/// Locates the eval model archive. `VIBRATO_FFI_UNIDIC_ZST` overrides the
/// dev-checkout path; a set-but-missing override skips instead of falling
/// back (the override is a deliberate statement about where the model lives).
fn model_zst() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("VIBRATO_FFI_UNIDIC_ZST") {
        let path = PathBuf::from(path);
        return path.is_file().then_some(path);
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../local/dictionaries/eval/unidic-mecab-2_1_2/system.dic.zst");
    path.is_file().then_some(path)
}

fn cstring(path: &Path) -> CString {
    CString::new(path.to_str().unwrap()).unwrap()
}

fn json_string(pointer: *mut c_char) -> String {
    assert!(!pointer.is_null(), "tokenize must return a JSON string");
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    unsafe { dictionary_free_string(pointer) };
    json
}

fn open_prepared() -> Option<(tempfile::TempDir, *mut DictionaryHandle)> {
    let model = model_zst()?;
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("unidic.dic");
    assert_eq!(
        unsafe { dictionary_prepare(cstring(&model).as_ptr(), cstring(&out).as_ptr()) },
        0,
        "dictionary_prepare must decompress the eval model"
    );
    let handle = unsafe { dictionary_open(cstring(&out).as_ptr()) };
    assert!(
        !handle.is_null(),
        "dictionary_open must accept the prepared dictionary"
    );
    Some((dir, handle))
}

#[test]
fn unidic_readings_bases_and_pos_live() {
    let Some((dir, handle)) = open_prepared() else {
        eprintln!(
            "skipping: unidic model not found — run scripts/eval_dictionary.sh first \
             (or set VIBRATO_FFI_UNIDIC_ZST)"
        );
        return;
    };
    let _keep = &dir;

    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("行っています").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json)
        .expect("valid JSON payload")
        .as_array()
        .expect("JSON array payload")
        .clone();

    // Per-surface readings (行っ → いっ, never the lemma reading いく), lemma
    // base forms (行っ → 行く), coarse POS. Probed shapes from the real model.
    let expected = [
        ("行っ", Some("いっ"), Some("行く"), "動詞"),
        ("て", Some("て"), Some("て"), "助詞"),
        ("い", Some("い"), Some("居る"), "動詞"),
        ("ます", Some("ます"), Some("ます"), "助動詞"),
    ];
    assert_eq!(tokens.len(), expected.len(), "payload: {json}");
    for (token, (surface, reading, base, pos)) in tokens.iter().zip(expected) {
        assert_eq!(token["text"].as_str(), Some(surface), "payload: {json}");
        assert_eq!(token["reading"].as_str(), reading, "payload: {json}");
        assert_eq!(token["base"].as_str(), base, "payload: {json}");
        assert_eq!(token["pos"].as_str(), Some(pos), "payload: {json}");
    }

    // 補助記号 folds to the IPADIC 記号 tag; punctuation carries no reading.
    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("。").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).unwrap();
    let tokens = tokens.as_array().unwrap();
    assert_eq!(tokens.len(), 1, "payload: {json}");
    assert_eq!(tokens[0]["text"].as_str(), Some("。"), "payload: {json}");
    assert!(tokens[0]["reading"].is_null(), "payload: {json}");
    assert_eq!(tokens[0]["base"].as_str(), Some("。"), "payload: {json}");
    assert_eq!(tokens[0]["pos"].as_str(), Some("記号"), "payload: {json}");

    unsafe { dictionary_free(handle) };
}

#[test]
fn unidic_lemma_kanji_form_and_scalar_spans_live() {
    let Some((dir, handle)) = open_prepared() else {
        eprintln!(
            "skipping: unidic model not found — run scripts/eval_dictionary.sh first \
             (or set VIBRATO_FFI_UNIDIC_ZST)"
        );
        return;
    };
    let _keep = &dir;

    // ダジャレ lemmatizes to its kanji form 駄洒落 (the JMDict tap-fallback
    // candidate), with the katakana surface reading folded to hiragana.
    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("ダジャレだ").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).unwrap();
    let tokens = tokens.as_array().unwrap();
    let expected = [
        ("ダジャレ", Some("だじゃれ"), Some("駄洒落"), "名詞"),
        ("だ", Some("だ"), Some("だ"), "助動詞"),
    ];
    assert_eq!(tokens.len(), expected.len(), "payload: {json}");
    for (token, (surface, reading, base, pos)) in tokens.iter().zip(expected) {
        assert_eq!(token["text"].as_str(), Some(surface), "payload: {json}");
        assert_eq!(token["reading"].as_str(), reading, "payload: {json}");
        assert_eq!(token["base"].as_str(), base, "payload: {json}");
        assert_eq!(token["pos"].as_str(), Some(pos), "payload: {json}");
    }

    // Spans still count scalars of the original input (SIP kanji, 4 bytes).
    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("𠮷野家").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).unwrap();
    let tokens = tokens.as_array().unwrap();
    assert_eq!(tokens.len(), 2, "payload: {json}");
    assert_eq!(tokens[0]["text"].as_str(), Some("𠮷"), "payload: {json}");
    assert_eq!(tokens[0]["start"].as_u64(), Some(0), "payload: {json}");
    assert_eq!(tokens[0]["end"].as_u64(), Some(1), "payload: {json}");
    assert_eq!(tokens[1]["text"].as_str(), Some("野家"), "payload: {json}");
    assert_eq!(tokens[1]["start"].as_u64(), Some(1), "payload: {json}");
    assert_eq!(tokens[1]["end"].as_u64(), Some(3), "payload: {json}");

    unsafe { dictionary_free(handle) };
}
