package i18nutil

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScanMessageKeysIncludesPublicStringLiterals(t *testing.T) {
	root := t.TempDir()
	source := `package sample

type Definition struct{ Msg string }

type builder struct{}

func (builder) Public(string) builder { return builder{} }

func use() {
    _ = Definition{Msg: "from_definition"}
    _ = builder{}.Public("from_public")
    _ = builder{}.Public(dynamic())
}

func dynamic() string { return "ignored_dynamic" }
`
	if err := os.WriteFile(filepath.Join(root, "sample.go"), []byte(source), 0o644); err != nil {
		t.Fatalf("write source: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "sample_test.go"), []byte(`package sample
func useTest() { _ = builder{}.Public("ignored_test") }
`), 0o644); err != nil {
		t.Fatalf("write test source: %v", err)
	}
	keys, err := ScanMessageKeys(root)
	if err != nil {
		t.Fatalf("ScanMessageKeys: %v", err)
	}
	got := map[string]bool{}
	for _, key := range keys {
		got[key] = true
	}
	for _, want := range []string{"from_definition", "from_public"} {
		if !got[want] {
			t.Fatalf("missing key %q from %v", want, keys)
		}
	}
	for _, want := range []string{"ignored_dynamic", "ignored_test"} {
		if got[want] {
			t.Fatalf("unexpected key %q in %v", want, keys)
		}
	}
}

func TestBuildReportIncludesGlossaryHintsAndSummary(t *testing.T) {
	locales := []LocaleFile{
		{
			Language: "zh-CN",
			Messages: map[string]string{"signature_missing": "签名信息缺失"},
		},
		{
			Language: "ja-JP",
			Messages: map[string]string{"signature_missing": "トークン情報が不足しています"},
		},
	}
	status := StatusFile{SourceLocale: "zh-CN", Locales: map[string]map[string]StatusEntry{
		"ja-JP": map[string]StatusEntry{
			"signature_missing": StatusEntry{Status: "reviewed"},
		},
	}}
	glossary := GlossaryFile{Terms: []GlossaryTerm{
		GlossaryTerm{
			Key: "signature",
			Translations: map[string]string{
				"zh-CN": "签名",
				"ja-JP": "署名",
			},
		},
	}}

	report, err := BuildReport("zh-CN", locales, status, glossary)
	if err != nil {
		t.Fatalf("BuildReport: %v", err)
	}
	if report.Summary.LocaleCount != 2 || report.Summary.MessageKeyCount != 1 {
		t.Fatalf("unexpected summary: %+v", report.Summary)
	}
	if len(report.GlossaryHints) != 1 {
		t.Fatalf("glossary hints = %d, want 1", len(report.GlossaryHints))
	}
	hint := report.GlossaryHints[0]
	if hint.Language != "ja-JP" || hint.Key != "signature_missing" || hint.Recommended != "署名" {
		t.Fatalf("unexpected glossary hint: %+v", hint)
	}
}
