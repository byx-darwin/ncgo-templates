package middleware

import (
	"context"
	"testing"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
)

func TestInternalOnlyRejectsUnavailableRemoteIP(t *testing.T) {
	c := app.NewContext(0)
	req := protocol.NewRequest("GET", "/healthz", nil)
	req.CopyTo(&c.Request)

	InternalOnly([]string{"/healthz"}, []string{"127.0.0.0/8"})(context.Background(), c)

	if c.Response.StatusCode() != consts.StatusForbidden {
		t.Fatalf("status = %d, want %d", c.Response.StatusCode(), consts.StatusForbidden)
	}
	if got, want := string(c.Response.Body()), `{"code":10108,"msg":"permission_denied"}`; got != want {
		t.Fatalf("body = %s, want %s", got, want)
	}
}

func TestPathSkipperSupportsWildcardPrefix(t *testing.T) {
	c := app.NewContext(0)
	req := protocol.NewRequest("GET", "/swagger/index.html", nil)
	req.CopyTo(&c.Request)

	if !PathSkipper("/swagger/*")(context.Background(), c) {
		t.Fatalf("expected wildcard path to be skipped")
	}
}
