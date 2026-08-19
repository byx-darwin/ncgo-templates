package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/tools/i18n/util"
)

func main() {
	localesDir := flag.String("locales", "internal/pkg/i18n/locales", "directory containing locale JSON files")
	statusPath := flag.String("status", "internal/pkg/i18n/.meta/status.json", "status JSON path")
	glossaryPath := flag.String("glossary", "internal/pkg/i18n/glossary.json", "glossary JSON path")
	sourceLocale := flag.String("source", "zh-CN", "source locale")
	mode := flag.String("mode", "dev", "check mode: dev or release")
	flag.Parse()

	locales, _, err := i18nutil.LoadLocales(*localesDir)
	if err != nil {
		fatal(err)
	}
	status, err := i18nutil.LoadStatus(*statusPath, *sourceLocale)
	if err != nil {
		fatal(err)
	}
	source := i18nutil.FindLocale(locales, *sourceLocale)
	if source == nil {
		fatal(fmt.Errorf("source locale %q not found", *sourceLocale))
	}
	glossary, err := i18nutil.LoadGlossary(*glossaryPath)
	if err != nil {
		fatal(err)
	}
	report, err := i18nutil.BuildReport(*sourceLocale, locales, status, glossary)
	if err != nil {
		fatal(err)
	}

	var failures []string
	for _, item := range report.MissingSource {
		failures = append(failures, fmt.Sprintf("missing source message for %s", item.Key))
	}
	for _, loc := range locales {
		for _, key := range i18nutil.SortedKeys(loc.Messages) {
			if strings.TrimSpace(key) == "" {
				failures = append(failures, fmt.Sprintf("%s has empty message key", loc.Language))
				continue
			}
			if strings.TrimSpace(loc.Messages[key]) == "" {
				failures = append(failures, fmt.Sprintf("%s/%s has empty translation", loc.Language, key))
			}
		}
	}
	for _, item := range report.MissingTranslations {
		if strings.TrimSpace(item.CurrentText) == "" {
			failures = append(failures, fmt.Sprintf("%s/%s is missing", item.Language, item.Key))
		} else if *mode == "release" {
			failures = append(failures, fmt.Sprintf("%s/%s is still placeholder text", item.Language, item.Key))
		}
	}
	for i := range locales {
		loc := locales[i]
		if loc.Language == *sourceLocale {
			continue
		}
		for _, key := range i18nutil.SortedKeys(source.Messages) {
			sourceText := source.Messages[key]
			currentText := loc.Messages[key]
			if i18nutil.IsPlaceholder(sourceText) || i18nutil.IsPlaceholder(currentText) {
				continue
			}
			if !equalTokens(i18nutil.PlaceholderTokens(sourceText), i18nutil.PlaceholderTokens(currentText)) {
				failures = append(failures, fmt.Sprintf("%s/%s placeholder mismatch", loc.Language, key))
			}
		}
	}
	if *mode == "release" {
		for _, item := range report.DraftTranslations {
			failures = append(failures, fmt.Sprintf("%s/%s is draft", item.Language, item.Key))
		}
		for _, item := range report.StaleTranslations {
			failures = append(failures, fmt.Sprintf("%s/%s is stale", item.Language, item.Key))
		}
	}
	for _, hint := range report.GlossaryHints {
		fmt.Fprintf(os.Stderr, "i18n-check: warning: %s/%s may not use recommended glossary term %q (want %q)\n", hint.Language, hint.Key, hint.Term, hint.Recommended)
	}
	if len(failures) > 0 {
		fatal(errors.New(strings.Join(failures, "\n")))
	}
}

func equalTokens(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "i18n-check:", err)
	os.Exit(1)
}
