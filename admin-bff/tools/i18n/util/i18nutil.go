package i18nutil

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const PlaceholderPrefix = "__TODO__: "

type LocaleFile struct {
	Language string            `json:"language"`
	Aliases  []string          `json:"aliases"`
	Messages map[string]string `json:"messages"`
}

type StatusFile struct {
	SourceLocale string                            `json:"source_locale"`
	Locales      map[string]map[string]StatusEntry `json:"locales"`
}

type StatusEntry struct {
	Status       string `json:"status,omitempty"`
	SourceLocale string `json:"source_locale,omitempty"`
	SourceHash   string `json:"source_hash,omitempty"`
	UpdatedAt    string `json:"updated_at,omitempty"`
	UpdatedBy    string `json:"updated_by,omitempty"`
	Note         string `json:"note,omitempty"`
}

type GlossaryFile struct {
	Terms []GlossaryTerm `json:"terms"`
}

type GlossaryTerm struct {
	Key          string            `json:"key"`
	Translations map[string]string `json:"translations"`
	Notes        string            `json:"notes,omitempty"`
}

type Report struct {
	Summary             ReportSummary  `json:"summary"`
	SourceLocale        string         `json:"source_locale"`
	MissingSource       []ReportItem   `json:"missing_source"`
	MissingTranslations []ReportItem   `json:"missing_translations"`
	StaleTranslations   []ReportItem   `json:"stale_translations"`
	DraftTranslations   []ReportItem   `json:"draft_translations"`
	ExtraKeys           []ReportItem   `json:"extra_keys"`
	GlossaryHints       []GlossaryHint `json:"glossary_hints"`
}

type ReportSummary struct {
	LocaleCount              int `json:"locale_count"`
	MessageKeyCount          int `json:"message_key_count"`
	MissingSourceCount       int `json:"missing_source_count"`
	MissingTranslationsCount int `json:"missing_translations_count"`
	StaleTranslationsCount   int `json:"stale_translations_count"`
	DraftTranslationsCount   int `json:"draft_translations_count"`
	ExtraKeysCount           int `json:"extra_keys_count"`
	GlossaryHintsCount       int `json:"glossary_hints_count"`
}

type ReportItem struct {
	Language    string `json:"language"`
	Key         string `json:"key"`
	SourceText  string `json:"source_text,omitempty"`
	CurrentText string `json:"current_text,omitempty"`
	Status      string `json:"status,omitempty"`
}

type GlossaryHint struct {
	Language    string `json:"language"`
	Key         string `json:"key"`
	Term        string `json:"term"`
	Recommended string `json:"recommended"`
	CurrentText string `json:"current_text,omitempty"`
}

var (
	goFmtPlaceholder = regexp.MustCompile(`%[sdv]`)
	namedPlaceholder = regexp.MustCompile(`\{[A-Za-z0-9_]+\}`)
)

func PlaceholderForKey(key string) string {
	return PlaceholderPrefix + strings.TrimSpace(key)
}

func IsPlaceholder(message string) bool {
	msg := strings.TrimSpace(message)
	return msg == "" || strings.HasPrefix(msg, PlaceholderPrefix)
}

func HashText(message string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(message)))
	return hex.EncodeToString(sum[:8])
}

func LoadLocales(dir string) ([]LocaleFile, map[string]string, error) {
	var locales []LocaleFile
	paths := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".json") {
			return err
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var loc LocaleFile
		if err := json.Unmarshal(body, &loc); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if strings.TrimSpace(loc.Language) == "" {
			return fmt.Errorf("%s: language is required", path)
		}
		if loc.Messages == nil {
			loc.Messages = map[string]string{}
		}
		locales = append(locales, loc)
		paths[loc.Language] = path
		return nil
	})
	sort.Slice(locales, func(i, j int) bool { return locales[i].Language < locales[j].Language })
	return locales, paths, err
}

func SaveLocale(path string, loc LocaleFile) error {
	if loc.Messages == nil {
		loc.Messages = map[string]string{}
	}
	sort.Strings(loc.Aliases)
	body, err := json.MarshalIndent(loc, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, append(body, '\n'), 0o644)
}

func FindLocale(locales []LocaleFile, language string) *LocaleFile {
	for i := range locales {
		if locales[i].Language == language {
			return &locales[i]
		}
	}
	return nil
}

func LoadStatus(path, sourceLocale string) (StatusFile, error) {
	status := StatusFile{SourceLocale: sourceLocale, Locales: map[string]map[string]StatusEntry{}}
	body, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return status, nil
		}
		return StatusFile{}, err
	}
	if err := json.Unmarshal(body, &status); err != nil {
		return StatusFile{}, fmt.Errorf("%s: %w", path, err)
	}
	if status.SourceLocale == "" {
		status.SourceLocale = sourceLocale
	}
	if status.Locales == nil {
		status.Locales = map[string]map[string]StatusEntry{}
	}
	return status, nil
}

func LoadGlossary(path string) (GlossaryFile, error) {
	glossary := GlossaryFile{}
	body, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return glossary, nil
		}
		return GlossaryFile{}, err
	}
	if err := json.Unmarshal(body, &glossary); err != nil {
		return GlossaryFile{}, fmt.Errorf("%s: %w", path, err)
	}
	return glossary, nil
}

func SaveStatus(path string, status StatusFile) error {
	if status.Locales == nil {
		status.Locales = map[string]map[string]StatusEntry{}
	}
	body, err := json.MarshalIndent(status, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, append(body, '\n'), 0o644)
}

func ScanMessageKeys(root string) ([]string, error) {
	keys := map[string]struct{}{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "vendor", "node_modules", "output":
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.CompositeLit)
			if ok {
				for _, elt := range lit.Elts {
					kv, ok := elt.(*ast.KeyValueExpr)
					if !ok {
						continue
					}
					ident, ok := kv.Key.(*ast.Ident)
					if !ok || ident.Name != "Msg" {
						continue
					}
					value, ok := kv.Value.(*ast.BasicLit)
					if !ok || value.Kind != token.STRING {
						continue
					}
					key, err := strconv.Unquote(value.Value)
					if err == nil && strings.TrimSpace(key) != "" {
						keys[key] = struct{}{}
					}
				}
			}
			call, ok := n.(*ast.CallExpr)
			if ok {
				if selector, ok := call.Fun.(*ast.SelectorExpr); ok && selector.Sel.Name == "Public" && len(call.Args) > 0 {
					if value, ok := call.Args[0].(*ast.BasicLit); ok && value.Kind == token.STRING {
						key, err := strconv.Unquote(value.Value)
						if err == nil && strings.TrimSpace(key) != "" {
							keys[key] = struct{}{}
						}
					}
				}
			}
			return true
		})
		return nil
	})
	return sortedSet(keys), err
}

func BuildReport(sourceLocale string, locales []LocaleFile, status StatusFile, glossary GlossaryFile) (Report, error) {
	report := Report{SourceLocale: sourceLocale}
	source := FindLocale(locales, sourceLocale)
	if source == nil {
		return report, fmt.Errorf("source locale %q not found", sourceLocale)
	}
	for _, key := range SortedKeys(source.Messages) {
		sourceText := source.Messages[key]
		if IsPlaceholder(sourceText) {
			report.MissingSource = append(report.MissingSource, ReportItem{
				Language:    sourceLocale,
				Key:         key,
				SourceText:  sourceText,
				CurrentText: sourceText,
				Status:      StatusFor(status, sourceLocale, key),
			})
		}
	}
	for i := range locales {
		loc := locales[i]
		if loc.Language == sourceLocale {
			continue
		}
		for _, key := range SortedKeys(source.Messages) {
			sourceText := source.Messages[key]
			currentText, ok := loc.Messages[key]
			currentStatus := StatusFor(status, loc.Language, key)
			if !ok || IsPlaceholder(currentText) {
				report.MissingTranslations = append(report.MissingTranslations, ReportItem{
					Language:    loc.Language,
					Key:         key,
					SourceText:  sourceText,
					CurrentText: currentText,
					Status:      currentStatus,
				})
				continue
			}
			switch currentStatus {
			case "stale":
				report.StaleTranslations = append(report.StaleTranslations, ReportItem{Language: loc.Language, Key: key, SourceText: sourceText, CurrentText: currentText, Status: currentStatus})
			case "draft":
				report.DraftTranslations = append(report.DraftTranslations, ReportItem{Language: loc.Language, Key: key, SourceText: sourceText, CurrentText: currentText, Status: currentStatus})
			}
		}
		for _, key := range SortedKeys(loc.Messages) {
			if _, ok := source.Messages[key]; !ok {
				report.ExtraKeys = append(report.ExtraKeys, ReportItem{Language: loc.Language, Key: key, CurrentText: loc.Messages[key], Status: StatusFor(status, loc.Language, key)})
			}
		}
	}
	sortReportItems(report.MissingSource)
	sortReportItems(report.MissingTranslations)
	sortReportItems(report.StaleTranslations)
	sortReportItems(report.DraftTranslations)
	sortReportItems(report.ExtraKeys)
	report.GlossaryHints = BuildGlossaryHints(sourceLocale, locales, glossary)
	sortGlossaryHints(report.GlossaryHints)
	report.Summary = ReportSummary{
		LocaleCount:              len(locales),
		MessageKeyCount:          len(source.Messages),
		MissingSourceCount:       len(report.MissingSource),
		MissingTranslationsCount: len(report.MissingTranslations),
		StaleTranslationsCount:   len(report.StaleTranslations),
		DraftTranslationsCount:   len(report.DraftTranslations),
		ExtraKeysCount:           len(report.ExtraKeys),
		GlossaryHintsCount:       len(report.GlossaryHints),
	}
	return report, nil
}

func BuildGlossaryHints(sourceLocale string, locales []LocaleFile, glossary GlossaryFile) []GlossaryHint {
	source := FindLocale(locales, sourceLocale)
	if source == nil {
		return nil
	}
	var hints []GlossaryHint
	for _, term := range glossary.Terms {
		sourceTerm := strings.TrimSpace(term.Translations[sourceLocale])
		if sourceTerm == "" {
			continue
		}
		for i := range locales {
			loc := locales[i]
			if loc.Language == sourceLocale {
				continue
			}
			targetTerm := strings.TrimSpace(term.Translations[loc.Language])
			if targetTerm == "" {
				continue
			}
			for _, key := range SortedKeys(source.Messages) {
				sourceText := source.Messages[key]
				currentText := loc.Messages[key]
				if IsPlaceholder(sourceText) || IsPlaceholder(currentText) {
					continue
				}
				if strings.Contains(sourceText, sourceTerm) && !strings.Contains(currentText, targetTerm) {
					hints = append(hints, GlossaryHint{
						Language:    loc.Language,
						Key:         key,
						Term:        term.Key,
						Recommended: targetTerm,
						CurrentText: currentText,
					})
				}
			}
		}
	}
	return hints
}

func MarkdownReport(report Report) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# i18n Report\n\n")
	fmt.Fprintf(&b, "- source locale: `%s`\n", report.SourceLocale)
	fmt.Fprintf(&b, "- locale count: %d\n", report.Summary.LocaleCount)
	fmt.Fprintf(&b, "- message key count: %d\n", report.Summary.MessageKeyCount)
	fmt.Fprintf(&b, "- missing source: %d\n", report.Summary.MissingSourceCount)
	fmt.Fprintf(&b, "- missing translations: %d\n", report.Summary.MissingTranslationsCount)
	fmt.Fprintf(&b, "- stale translations: %d\n", report.Summary.StaleTranslationsCount)
	fmt.Fprintf(&b, "- draft translations: %d\n", report.Summary.DraftTranslationsCount)
	fmt.Fprintf(&b, "- extra keys: %d\n", report.Summary.ExtraKeysCount)
	fmt.Fprintf(&b, "- glossary hints: %d\n\n", report.Summary.GlossaryHintsCount)
	writeSection := func(title string, items []ReportItem) {
		fmt.Fprintf(&b, "## %s\n\n", title)
		if len(items) == 0 {
			b.WriteString("- none\n\n")
			return
		}
		for _, item := range items {
			fmt.Fprintf(&b, "- `%s` / `%s`", item.Language, item.Key)
			if item.SourceText != "" {
				fmt.Fprintf(&b, " | source: `%s`", item.SourceText)
			}
			if strings.TrimSpace(item.CurrentText) != "" {
				fmt.Fprintf(&b, " | current: `%s`", item.CurrentText)
			}
			if item.Status != "" {
				fmt.Fprintf(&b, " | status: `%s`", item.Status)
			}
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}
	writeSection("Missing source messages", report.MissingSource)
	writeSection("Missing translations", report.MissingTranslations)
	writeSection("Stale translations", report.StaleTranslations)
	writeSection("Draft translations", report.DraftTranslations)
	writeSection("Extra keys", report.ExtraKeys)
	fmt.Fprintf(&b, "## Glossary hints\n\n")
	if len(report.GlossaryHints) == 0 {
		b.WriteString("- none\n\n")
	} else {
		for _, hint := range report.GlossaryHints {
			fmt.Fprintf(&b, "- `%s` / `%s` | term: `%s` | recommended: `%s` | current: `%s`\n", hint.Language, hint.Key, hint.Term, hint.Recommended, hint.CurrentText)
		}
		b.WriteString("\n")
	}
	return b.String()
}

func PlaceholderTokens(message string) []string {
	tokens := append([]string{}, goFmtPlaceholder.FindAllString(message, -1)...)
	tokens = append(tokens, namedPlaceholder.FindAllString(message, -1)...)
	sort.Strings(tokens)
	return tokens
}

func StatusFor(status StatusFile, language, key string) string {
	if status.Locales == nil {
		return ""
	}
	return status.Locales[language][key].Status
}

func SortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sortedSet(values map[string]struct{}) []string {
	items := make([]string, 0, len(values))
	for value := range values {
		items = append(items, value)
	}
	sort.Strings(items)
	return items
}

func sortReportItems(items []ReportItem) {
	sort.Slice(items, func(i, j int) bool {
		if items[i].Language == items[j].Language {
			return items[i].Key < items[j].Key
		}
		return items[i].Language < items[j].Language
	})
}

func sortGlossaryHints(items []GlossaryHint) {
	sort.Slice(items, func(i, j int) bool {
		if items[i].Language == items[j].Language {
			if items[i].Key == items[j].Key {
				return items[i].Term < items[j].Term
			}
			return items[i].Key < items[j].Key
		}
		return items[i].Language < items[j].Language
	})
}
