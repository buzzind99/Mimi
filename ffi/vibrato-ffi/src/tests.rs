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
    assert_eq!(
        reading_from_features(&row, FeatureScheme::Ipadic, "ミミ"),
        None
    );
    assert_eq!(
        reading_from_features(&[], FeatureScheme::Ipadic, "ミミ"),
        None
    );
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
    assert_eq!(
        reading_from_features(&row, FeatureScheme::Ipadic, "ぼ"),
        None
    );
    // 8-column shape with an empty reading.
    let row = parse_csv_row("名詞,一般,*,*,*,*,*,");
    assert_eq!(
        reading_from_features(&row, FeatureScheme::Ipadic, "ぼ"),
        None
    );
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
    assert_eq!(
        reading_from_features(&row, FeatureScheme::Unidic, "。"),
        None
    );
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
    let row = parse_csv_row(
        "名詞,普通名詞,一般,*,*,*,ダジャレ,駄洒落,ダジャレ,ダジャレ,ダジャレ,ダジャレ,混,*,*,*,*",
    );
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
