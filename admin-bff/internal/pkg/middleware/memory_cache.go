package middleware

const defaultMemoryCacheMaxEntries = 100000

func memoryCacheMaxEntries(configured int) int {
	if configured <= 0 {
		return defaultMemoryCacheMaxEntries
	}
	return configured
}
