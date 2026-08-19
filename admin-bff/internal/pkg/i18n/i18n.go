package i18n

import (
	"sort"
	"strconv"
	"strings"
	"sync"
)

const (
	HeaderAcceptLanguage  = "Accept-Language"
	HeaderContentLanguage = "Content-Language"
	DefaultLanguage       = "en"
	SimplifiedChinese     = "zh-CN"
	TraditionalChinese    = "zh-TW"
	Japanese              = "ja-JP"
	Korean                = "ko-KR"
	French                = "fr-FR"
	German                = "de-DE"
	Spanish               = "es-ES"
)

var (
	catalogMu       sync.RWMutex
	catalog         = map[string]map[string]string{}
	languageAliases = map[string]string{}
)

func init() {
	RegisterLanguage(DefaultLanguage, "en")
	RegisterLanguage(SimplifiedChinese, "zh", "zh-CN", "zh-Hans")
	RegisterLanguage(TraditionalChinese, "zh-TW", "zh-Hant", "zh-HK", "zh-MO")
	RegisterLanguage(Japanese, "ja")
	RegisterLanguage(Korean, "ko")
	RegisterLanguage(French, "fr")
	RegisterLanguage(German, "de")
	RegisterLanguage(Spanish, "es")
}

func RegisterLanguage(language string, aliases ...string) string {
	language = strings.TrimSpace(language)
	if language == "" || language == "*" {
		panic("i18n: language must not be empty")
	}
	catalogMu.Lock()
	defer catalogMu.Unlock()
	if catalog[language] == nil {
		catalog[language] = map[string]string{}
	}
	registerLanguageAliasLocked(language, language)
	for _, alias := range aliases {
		registerLanguageAliasLocked(language, alias)
	}
	return language
}

func registerLanguageAliasLocked(language, alias string) {
	alias = languageKey(alias)
	if alias == "" || alias == "*" {
		return
	}
	languageAliases[alias] = language
}

func Register(language, key, message string) {
	if lang, ok := supportedLanguage(language); ok {
		language = lang
	} else {
		language = RegisterLanguage(language)
	}
	key, message = strings.TrimSpace(key), strings.TrimSpace(message)
	if key == "" || message == "" {
		panic("i18n: language key and message must not be empty")
	}
	catalogMu.Lock()
	defer catalogMu.Unlock()
	if catalog[language] == nil {
		catalog[language] = map[string]string{}
	}
	catalog[language][key] = message
}

func Translate(language, key string) string {
	language, key = Normalize(language), strings.TrimSpace(key)
	if key == "" || language == DefaultLanguage {
		return key
	}
	catalogMu.RLock()
	defer catalogMu.RUnlock()
	if messages := catalog[language]; messages != nil {
		if msg := messages[key]; msg != "" {
			return msg
		}
	}
	return key
}

func FromAcceptLanguage(header string) string {
	candidates := parseAcceptLanguage(header)
	for _, candidate := range candidates {
		if lang, ok := supportedLanguage(candidate.Tag); ok {
			return lang
		}
	}
	return DefaultLanguage
}

func Normalize(language string) string {
	if lang, ok := supportedLanguage(language); ok {
		return lang
	}
	return DefaultLanguage
}

func supportedLanguage(language string) (string, bool) {
	key := languageKey(language)
	if key == "" || key == "*" {
		return DefaultLanguage, true
	}
	catalogMu.RLock()
	defer catalogMu.RUnlock()
	for {
		if lang, ok := languageAliases[key]; ok {
			return lang, true
		}
		i := strings.LastIndex(key, "-")
		if i <= 0 {
			return "", false
		}
		key = key[:i]
	}
}

func languageKey(language string) string {
	return strings.ToLower(strings.ReplaceAll(strings.TrimSpace(language), "_", "-"))
}

type languageCandidate struct {
	Tag     string
	Quality float64
	Index   int
}

func parseAcceptLanguage(header string) []languageCandidate {
	parts := strings.Split(header, ",")
	candidates := make([]languageCandidate, 0, len(parts))
	for i, part := range parts {
		tag, quality := parseLanguagePart(part)
		if tag == "" || quality <= 0 {
			continue
		}
		candidates = append(candidates, languageCandidate{Tag: tag, Quality: quality, Index: i})
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].Quality == candidates[j].Quality {
			return candidates[i].Index < candidates[j].Index
		}
		return candidates[i].Quality > candidates[j].Quality
	})
	return candidates
}

func parseLanguagePart(part string) (string, float64) {
	segments := strings.Split(strings.TrimSpace(part), ";")
	tag := strings.TrimSpace(segments[0])
	quality := 1.0
	for _, segment := range segments[1:] {
		key, value, ok := strings.Cut(strings.TrimSpace(segment), "=")
		if ok && strings.TrimSpace(key) == "q" {
			if parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err == nil {
				quality = parsed
			}
		}
	}
	return tag, quality
}
