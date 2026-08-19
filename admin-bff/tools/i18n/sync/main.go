package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/tools/i18n/util"
)

func main() {
	root := flag.String("root", ".", "project root to scan for message keys")
	localesDir := flag.String("locales", "internal/pkg/i18n/locales", "directory containing locale JSON files")
	statusPath := flag.String("status", "internal/pkg/i18n/.meta/status.json", "status JSON path")
	sourceLocale := flag.String("source", "zh-CN", "source locale")
	flag.Parse()

	locales, paths, err := i18nutil.LoadLocales(*localesDir)
	if err != nil {
		fatal(err)
	}
	source := i18nutil.FindLocale(locales, *sourceLocale)
	if source == nil {
		fatal(fmt.Errorf("source locale %q not found", *sourceLocale))
	}
	status, err := i18nutil.LoadStatus(*statusPath, *sourceLocale)
	if err != nil {
		fatal(err)
	}
	keysFromCode, err := i18nutil.ScanMessageKeys(*root)
	if err != nil {
		fatal(err)
	}

	keySet := map[string]struct{}{}
	for key := range source.Messages {
		keySet[key] = struct{}{}
	}
	for _, key := range keysFromCode {
		keySet[key] = struct{}{}
	}
	keys := make([]string, 0, len(keySet))
	for key := range keySet {
		keys = append(keys, key)
	}
	if status.Locales == nil {
		status.Locales = map[string]map[string]i18nutil.StatusEntry{}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	saveStatus := false
	saveLocale := map[string]bool{}
	for i := range locales {
		if status.Locales[locales[i].Language] == nil {
			status.Locales[locales[i].Language] = map[string]i18nutil.StatusEntry{}
			saveStatus = true
		}
	}

	for _, key := range keys {
		sourceText, ok := source.Messages[key]
		if !ok {
			sourceText = i18nutil.PlaceholderForKey(key)
			source.Messages[key] = sourceText
			saveLocale[*sourceLocale] = true
		}
		sourceHash := i18nutil.HashText(sourceText)
		if upsertStatus(&status, *sourceLocale, key, statusForMessage(sourceText, ""), *sourceLocale, sourceHash, "sync", now) {
			saveStatus = true
		}
		for i := range locales {
			loc := &locales[i]
			if loc.Language == *sourceLocale {
				continue
			}
			currentText, ok := loc.Messages[key]
			if !ok {
				currentText = i18nutil.PlaceholderForKey(key)
				loc.Messages[key] = currentText
				saveLocale[loc.Language] = true
			}
			previous := status.Locales[loc.Language][key]
			desired := previous.Status
			switch {
			case i18nutil.IsPlaceholder(currentText):
				desired = "draft"
			case previous.SourceHash != "" && previous.SourceHash != sourceHash:
				desired = "stale"
			case desired == "":
				desired = "reviewed"
			}
			if upsertStatus(&status, loc.Language, key, desired, *sourceLocale, sourceHash, "sync", now) {
				saveStatus = true
			}
		}
	}

	for _, loc := range locales {
		if saveLocale[loc.Language] {
			if err := i18nutil.SaveLocale(paths[loc.Language], loc); err != nil {
				fatal(err)
			}
		}
	}
	if saveStatus {
		if err := i18nutil.SaveStatus(*statusPath, status); err != nil {
			fatal(err)
		}
	}
}

func statusForMessage(message, current string) string {
	if i18nutil.IsPlaceholder(message) {
		return "draft"
	}
	if current != "" {
		return current
	}
	return "reviewed"
}

func upsertStatus(status *i18nutil.StatusFile, language, key, state, sourceLocale, sourceHash, actor, now string) bool {
	current := status.Locales[language][key]
	next := current
	next.Status = state
	next.SourceLocale = sourceLocale
	next.SourceHash = sourceHash
	changed := current.Status != next.Status || current.SourceLocale != next.SourceLocale || current.SourceHash != next.SourceHash
	if changed {
		next.UpdatedAt = now
		next.UpdatedBy = actor
	}
	status.Locales[language][key] = next
	return changed
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "i18n-sync:", err)
	os.Exit(1)
}
