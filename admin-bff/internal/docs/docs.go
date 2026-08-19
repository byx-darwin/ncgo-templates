package docs

import _ "embed"

//go:embed swagger/openapi.yaml
var openAPIYAML []byte

// OpenAPIYAML returns the embedded Swagger / OpenAPI spec.
func OpenAPIYAML() []byte {
	return openAPIYAML
}
