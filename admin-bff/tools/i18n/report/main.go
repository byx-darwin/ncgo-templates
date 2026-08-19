package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/tools/i18n/util"
)

func main() {
	localesDir := flag.String("locales", "internal/pkg/i18n/locales", "directory containing locale JSON files")
	statusPath := flag.String("status", "internal/pkg/i18n/.meta/status.json", "status JSON path")
	glossaryPath := flag.String("glossary", "internal/pkg/i18n/glossary.json", "glossary JSON path")
	sourceLocale := flag.String("source", "zh-CN", "source locale")
	outMD := flag.String("out-md", "internal/pkg/i18n/.meta/report.md", "markdown report output path")
	outJSON := flag.String("out-json", "internal/pkg/i18n/.meta/report.json", "json report output path")
	flag.Parse()

	locales, _, err := i18nutil.LoadLocales(*localesDir)
	if err != nil {
		fatal(err)
	}
	status, err := i18nutil.LoadStatus(*statusPath, *sourceLocale)
	if err != nil {
		fatal(err)
	}
	glossary, err := i18nutil.LoadGlossary(*glossaryPath)
	if err != nil {
		fatal(err)
	}
	report, err := i18nutil.BuildReport(*sourceLocale, locales, status, glossary)
	if err != nil {
		fatal(err)
	}
	if err := writeFile(*outMD, []byte(i18nutil.MarkdownReport(report))); err != nil {
		fatal(err)
	}
	body, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		fatal(err)
	}
	if err := writeFile(*outJSON, append(body, '\n')); err != nil {
		fatal(err)
	}
}

func writeFile(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, body, 0o644)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "i18n-report:", err)
	os.Exit(1)
}
