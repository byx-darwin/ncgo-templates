package middleware

import (
	"context"
	"strconv"
	"testing"
	"time"

	config "github.com/byx-darwin/go-tools/go-framework/config"
	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol"
	"github.com/cloudwego/hertz/pkg/protocol/consts"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
)

func TestSignatureNonceRejectsReplay(t *testing.T) {
	cfg := conf.SignatureConfig{Enabled: true, StaticSecret: "secret", Nonce: conf.SignatureNonceConfig{Enabled: true, Backend: "memory", KeyPrefix: "test", TTLSeconds: config.Duration{Duration: 300 * time.Second}}}
	mw := SignatureAuth(cfg, StaticSecretResolver{SecretValue: "secret"})
	timestamp := strconv.FormatInt(time.Now().Unix(), 10)

	first := newSignedSignatureContext(t, "secret", "app-1", "nonce-1", timestamp)
	mw(context.Background(), first)
	if first.Response.StatusCode() == consts.StatusConflict {
		t.Fatalf("first request was treated as replay")
	}

	second := newSignedSignatureContext(t, "secret", "app-1", "nonce-1", timestamp)
	mw(context.Background(), second)
	if second.Response.StatusCode() != consts.StatusConflict {
		t.Fatalf("status = %d, want %d", second.Response.StatusCode(), consts.StatusConflict)
	}
	if got, want := string(second.Response.Body()), `{"code":10202,"msg":"replay_request"}`; got != want {
		t.Fatalf("body = %s, want %s", got, want)
	}
}

func TestSignatureInvalidDoesNotConsumeNonce(t *testing.T) {
	cfg := conf.SignatureConfig{Enabled: true, StaticSecret: "secret", Nonce: conf.SignatureNonceConfig{Enabled: true, Backend: "memory", KeyPrefix: "test", TTLSeconds: config.Duration{Duration: 300 * time.Second}}}
	mw := SignatureAuth(cfg, StaticSecretResolver{SecretValue: "secret"})
	timestamp := strconv.FormatInt(time.Now().Unix(), 10)

	invalid := newSignedSignatureContext(t, "secret", "app-1", "nonce-2", timestamp)
	invalid.Request.Header.Set("X-Signature", "bad")
	mw(context.Background(), invalid)
	if invalid.Response.StatusCode() != consts.StatusForbidden {
		t.Fatalf("status = %d, want %d", invalid.Response.StatusCode(), consts.StatusForbidden)
	}

	valid := newSignedSignatureContext(t, "secret", "app-1", "nonce-2", timestamp)
	mw(context.Background(), valid)
	if valid.Response.StatusCode() == consts.StatusConflict {
		t.Fatalf("valid request was treated as replay after invalid signature")
	}
}

func TestSignatureNonceKeySanitizesParts(t *testing.T) {
	if got, want := signatureNonceKey("test", "app:1", "nonce 1"), "test:signature_nonce:app_1:nonce_1"; got != want {
		t.Fatalf("key = %q, want %q", got, want)
	}
}

func TestMemorySignatureNonceStoreEvictsLRU(t *testing.T) {
	store := newMemorySignatureNonceStore(1)
	if ok, err := store.Mark(context.Background(), "k1", time.Minute); err != nil || !ok {
		t.Fatalf("mark k1 = %v, %v", ok, err)
	}
	if ok, err := store.Mark(context.Background(), "k2", time.Minute); err != nil || !ok {
		t.Fatalf("mark k2 = %v, %v", ok, err)
	}
	if ok, err := store.Mark(context.Background(), "k1", time.Minute); err != nil || !ok {
		t.Fatalf("mark evicted k1 = %v, %v; want fresh insert after LRU eviction", ok, err)
	}
}

func newSignedSignatureContext(t *testing.T, secret, appKey, nonce, timestamp string) *app.RequestContext {
	t.Helper()
	c := app.NewContext(0)
	req := protocol.NewRequest("GET", "/ping?message=hello", nil)
	req.Header.Set("X-App-Key", appKey)
	req.Header.Set("X-Timestamp", timestamp)
	req.Header.Set("X-Nonce", nonce)
	req.CopyTo(&c.Request)
	c.Request.Header.Set("X-Signature", ComputeSignature(secret, CanonicalRequest(c, timestamp, nonce)))
	return c
}
