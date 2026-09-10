//! Integration test against the real IPADIC model — gated on the artifact
//! `scripts/build_dictionary.sh` fetches into
//! `local/dictionaries/ipadic-mecab-2_7_0/`. Each test skips visibly (with a
//! hint to run the script) when the model is absent, so `cargo test` stays
//! green on a fresh clone before the fetch.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

use serde_json::Value;
use vibrato_ffi::{
    dictionary_free, dictionary_free_string, dictionary_open, dictionary_prepare,
    dictionary_tokenize_json,
};

/// Locates the pinned model archive. `VIBRATO_FFI_MODEL_ZST` overrides the
/// dev-checkout path; a set-but-missing override skips instead of falling
/// back (the override is a deliberate statement about where the model lives).
fn model_zst() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("VIBRATO_FFI_MODEL_ZST") {
        let path = PathBuf::from(path);
        return path.is_file().then_some(path);
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst");
    path.is_file().then_some(path)
}

fn cstring(path: &Path) -> CString {
    CString::new(path.to_str().unwrap()).unwrap()
}

fn json_string(pointer: *mut std::ffi::c_char) -> String {
    assert!(!pointer.is_null(), "tokenize must return a JSON string");
    let json = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    unsafe { dictionary_free_string(pointer) };
    json
}

fn skip_unless_model() -> Option<PathBuf> {
    match model_zst() {
        Some(path) => Some(path),
        None => {
            eprintln!(
                "skipping: model not found — run scripts/build_dictionary.sh first \
                 (or set VIBRATO_FFI_MODEL_ZST)"
            );
            None
        }
    }
}

#[test]
fn prepare_then_open_then_tokenize_live() {
    let Some(model) = skip_unless_model() else {
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("ipadic.dic");

    // First-launch decompress: success, non-empty output, idempotent rerun.
    assert_eq!(
        unsafe { dictionary_prepare(cstring(&model).as_ptr(), cstring(&out).as_ptr()) },
        0,
        "dictionary_prepare must decompress the pinned model"
    );
    assert!(
        out.metadata().unwrap().len() > 1_000_000,
        "decompressed dictionary is implausibly small"
    );
    assert_eq!(
        unsafe { dictionary_prepare(cstring(&model).as_ptr(), cstring(&out).as_ptr()) },
        0,
        "dictionary_prepare must be idempotent"
    );

    let handle = unsafe { dictionary_open(cstring(&out).as_ptr()) };
    assert!(
        !handle.is_null(),
        "dictionary_open must accept the prepared dictionary"
    );

    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("私は学生です").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).expect("valid JSON payload");
    let tokens = tokens.as_array().expect("JSON array payload");

    // Phase 0 live smoke: 私/ワタシ + は/ハ + 学生/ガクセイ + です/デス — 4 tokens,
    // readings on all, hiragana-converted, scalar spans over the raw input.
    let expected = [
        ("私", 0, 1, Some("わたし")),
        ("は", 1, 2, Some("は")),
        ("学生", 2, 4, Some("がくせい")),
        ("です", 4, 6, Some("です")),
    ];
    assert_eq!(tokens.len(), expected.len(), "payload: {json}");
    for (token, (surface, start, end, reading)) in tokens.iter().zip(expected) {
        assert_eq!(token["text"].as_str(), Some(surface), "payload: {json}");
        assert_eq!(
            token["start"].as_u64(),
            Some(start as u64),
            "payload: {json}"
        );
        assert_eq!(token["end"].as_u64(), Some(end as u64), "payload: {json}");
        assert_eq!(token["reading"].as_str(), reading, "payload: {json}");
    }

    unsafe { dictionary_free(handle) };
}

#[test]
fn live_spans_are_original_input_scalar_indices() {
    let Some(model) = skip_unless_model() else {
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("ipadic.dic");
    assert_eq!(
        unsafe { dictionary_prepare(cstring(&model).as_ptr(), cstring(&out).as_ptr()) },
        0
    );
    let handle = unsafe { dictionary_open(cstring(&out).as_ptr()) };
    assert!(!handle.is_null());

    // 𠮷 (SIP, 4 bytes, unknown `*` reading) + 野家: vibrato does no
    // normalization, so spans must count scalars, not bytes or graphemes.
    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("𠮷野家").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).unwrap();
    let tokens = tokens.as_array().unwrap();
    let expected = [("𠮷", 0, 1, None), ("野家", 1, 3, Some("のや"))];
    assert_eq!(tokens.len(), expected.len(), "payload: {json}");
    for (token, (surface, start, end, reading)) in tokens.iter().zip(expected) {
        assert_eq!(token["text"].as_str(), Some(surface), "payload: {json}");
        assert_eq!(
            token["start"].as_u64(),
            Some(start as u64),
            "payload: {json}"
        );
        assert_eq!(token["end"].as_u64(), Some(end as u64), "payload: {json}");
        assert_eq!(token["reading"].as_str(), reading, "payload: {json}");
    }

    // Emoji and a whitespace gap (ignore_space): the gap stays uncovered and
    // the scalar after it keeps its absolute index.
    let json = json_string(unsafe {
        dictionary_tokenize_json(handle, CString::new("A B").unwrap().as_ptr())
    });
    let tokens = serde_json::from_str::<Value>(&json).unwrap();
    let tokens = tokens.as_array().unwrap();
    assert_eq!(tokens.len(), 2, "payload: {json}");
    assert_eq!(tokens[0]["text"].as_str(), Some("A"), "payload: {json}");
    assert_eq!(tokens[1]["text"].as_str(), Some("B"), "payload: {json}");
    assert_eq!(tokens[1]["start"].as_u64(), Some(2), "payload: {json}");

    unsafe { dictionary_free(handle) };
}

#[test]
fn ffi_rejects_bad_input_fail_soft() {
    // Missing dictionary file.
    let missing = CString::new("/nonexistent/mimi/ipadic.dic").unwrap();
    assert!(
        unsafe { dictionary_open(missing.as_ptr()) }.is_null(),
        "dictionary_open must return null for a missing file"
    );
    // Null arguments everywhere must fail, not crash.
    assert!(unsafe { dictionary_open(ptr::null()) }.is_null());
    assert!(unsafe { dictionary_tokenize_json(ptr::null_mut(), c"x".as_ptr()) }.is_null());
    let text = CString::new("学生").unwrap();
    assert!(unsafe { dictionary_tokenize_json(ptr::null_mut(), text.as_ptr()) }.is_null());
    // Free functions are no-ops on null.
    unsafe { dictionary_free(ptr::null_mut()) };
    unsafe { dictionary_free_string(ptr::null_mut()) };
    // Non-UTF-8 text fails softly.
    let handle = skip_unless_model().map(|model| {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("ipadic.dic");
        assert_eq!(
            unsafe { dictionary_prepare(cstring(&model).as_ptr(), cstring(&out).as_ptr()) },
            0
        );
        let handle = unsafe { dictionary_open(cstring(&out).as_ptr()) };
        assert!(!handle.is_null());
        (dir, handle)
    });
    if let Some((dir, handle)) = handle {
        let invalid_utf8 = unsafe { CString::from_vec_unchecked(vec![0xFF, 0xFE, 0x00]) };
        assert!(
            unsafe { dictionary_tokenize_json(handle, invalid_utf8.as_ptr()) }.is_null(),
            "invalid UTF-8 must return null"
        );
        // Empty input yields an empty array, not null.
        let json = json_string(unsafe { dictionary_tokenize_json(handle, c"".as_ptr()) });
        assert_eq!(json, "[]", "empty input must yield an empty array");
        unsafe { dictionary_free(handle) };
        drop(dir);
    }
}
