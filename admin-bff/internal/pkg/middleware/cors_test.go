package middleware

import (
	"context"
	"testing"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol"
	"github.com/cloudwego/hertz/pkg/protocol/consts"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
)

func TestCORSPreflightAllowed(t *testing.T) {
	c := app.NewContext(0)
	req := protocol.NewRequest("OPTIONS", "/ping", nil)
	req.Header.Set("Origin", "https://app.example.com")
	req.Header.Set("Access-Control-Request-Method", "GET")
	req.CopyTo(&c.Request)

	CORS(conf.CORSConfig{Enabled: true, AllowOrigins: []string{"https://app.example.com"}})(context.Background(), c)

	if c.Response.StatusCode() != consts.StatusNoContent {
		t.Fatalf("status = %d, want %d", c.Response.StatusCode(), consts.StatusNoContent)
	}
	if got := string(c.Response.Header.Peek("Access-Control-Allow-Origin")); got != "https://app.example.com" {
		t.Fatalf("allow origin = %q", got)
	}
}

func TestCORSPreflightRejected(t *testing.T) {
	c := app.NewContext(0)
	req := protocol.NewRequest("OPTIONS", "/ping", nil)
	req.Header.Set("Origin", "https://evil.example.com")
	req.Header.Set("Access-Control-Request-Method", "GET")
	req.CopyTo(&c.Request)

	CORS(conf.CORSConfig{Enabled: true, AllowOrigins: []string{"https://app.example.com"}})(context.Background(), c)

	if c.Response.StatusCode() != consts.StatusForbidden {
		t.Fatalf("status = %d, want %d", c.Response.StatusCode(), consts.StatusForbidden)
	}
	if got, want := string(c.Response.Body()), `{"code":10108,"msg":"permission_denied"}`; got != want {
		t.Fatalf("body = %s, want %s", got, want)
	}
}
