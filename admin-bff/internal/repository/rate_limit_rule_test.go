package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/db/gen"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/ratelimit"
)

type stubRateLimitRuleFinder struct {
	record *RateLimitRuleRecord
	err    error
	onFind func(service, phase, method, path, appKey string)
}

type stubRateLimitRuleQuerier struct {
	calls        []string
	seenServices []string

	exactAppKeyRow     *gen.GetRateLimitExactRuleByAppKeyRow
	exactAppKeyErr     error
	exactFallbackRow   *gen.GetRateLimitExactRuleFallbackRow
	exactFallbackErr   error
	patternAppKeyRow   *gen.GetRateLimitPatternRuleByAppKeyRow
	patternAppKeyErr   error
	patternFallbackRow *gen.GetRateLimitPatternRuleFallbackRow
	patternFallbackErr error
}

func (s *stubRateLimitRuleQuerier) GetRateLimitExactRuleByAppKey(ctx context.Context, arg *gen.GetRateLimitExactRuleByAppKeyParams) (*gen.GetRateLimitExactRuleByAppKeyRow, error) {
	_ = ctx
	if arg != nil {
		s.seenServices = append(s.seenServices, arg.Service)
	}
	s.calls = append(s.calls, "exact_app")
	return s.exactAppKeyRow, s.exactAppKeyErr
}

func (s *stubRateLimitRuleQuerier) GetRateLimitExactRuleFallback(ctx context.Context, arg *gen.GetRateLimitExactRuleFallbackParams) (*gen.GetRateLimitExactRuleFallbackRow, error) {
	_ = ctx
	if arg != nil {
		s.seenServices = append(s.seenServices, arg.Service)
	}
	s.calls = append(s.calls, "exact_fallback")
	return s.exactFallbackRow, s.exactFallbackErr
}

func (s *stubRateLimitRuleQuerier) GetRateLimitPatternRuleByAppKey(ctx context.Context, arg *gen.GetRateLimitPatternRuleByAppKeyParams) (*gen.GetRateLimitPatternRuleByAppKeyRow, error) {
	_ = ctx
	if arg != nil {
		s.seenServices = append(s.seenServices, arg.Service)
	}
	s.calls = append(s.calls, "pattern_app")
	return s.patternAppKeyRow, s.patternAppKeyErr
}

func (s *stubRateLimitRuleQuerier) GetRateLimitPatternRuleFallback(ctx context.Context, arg *gen.GetRateLimitPatternRuleFallbackParams) (*gen.GetRateLimitPatternRuleFallbackRow, error) {
	_ = ctx
	if arg != nil {
		s.seenServices = append(s.seenServices, arg.Service)
	}
	s.calls = append(s.calls, "pattern_fallback")
	return s.patternFallbackRow, s.patternFallbackErr
}

func (s stubRateLimitRuleFinder) FindRule(ctx context.Context, service, phase, method, path, appKey string) (*RateLimitRuleRecord, error) {
	_ = ctx
	if s.onFind != nil {
		s.onFind(service, phase, method, path, appKey)
	}
	_ = service
	_ = phase
	_ = method
	_ = path
	_ = appKey
	return s.record, s.err
}

func TestRateLimitRuleHookReturnsNotFoundWhenFinderNil(t *testing.T) {
	hook := NewRateLimitRuleHook(nil)
	rule, found, err := hook.ResolveRateLimitRule(context.Background(), ratelimit.Lookup{Service: "order-api", Phase: "pre_auth", Method: "GET", Path: "/orders"})
	if err != nil || found || rule != nil {
		t.Fatalf("got rule=%v found=%v err=%v, want nil false nil", rule, found, err)
	}
}

func TestRateLimitRuleHookMapsRepositoryRecord(t *testing.T) {
	hook := NewRateLimitRuleHook(stubRateLimitRuleFinder{record: &RateLimitRuleRecord{
		Enabled:          true,
		KeyBy:            []string{"ak_path"},
		Strategy:         "fixed_window",
		WindowSeconds:    60,
		MaxRequests:      9,
		ClientTTLSeconds: 90,
	}})
	rule, found, err := hook.ResolveRateLimitRule(context.Background(), ratelimit.Lookup{Service: "order-api", Phase: "post_auth", Method: "GET", Path: "/orders", AppKey: "app-1"})
	if err != nil || !found || rule == nil {
		t.Fatalf("got rule=%v found=%v err=%v, want mapped rule", rule, found, err)
	}
	if rule.MaxRequests != 9 || rule.WindowSeconds.Duration != 60*time.Second || len(rule.KeyBy) != 1 || rule.KeyBy[0] != "ak_path" {
		t.Fatalf("unexpected mapped rule: %+v", rule)
	}
}

func TestRateLimitRuleHookPropagatesRepositoryError(t *testing.T) {
	hook := NewRateLimitRuleHook(stubRateLimitRuleFinder{err: errors.New("boom")})
	rule, found, err := hook.ResolveRateLimitRule(context.Background(), ratelimit.Lookup{Service: "order-api", Phase: "pre_auth", Method: "GET", Path: "/orders"})
	if err == nil || found || rule != nil {
		t.Fatalf("got rule=%v found=%v err=%v, want nil false error", rule, found, err)
	}
}

func TestRateLimitRuleHookForwardsServiceToFinder(t *testing.T) {
	gotService := ""
	hook := NewRateLimitRuleHook(stubRateLimitRuleFinder{onFind: func(service, phase, method, path, appKey string) {
		gotService = service
		_ = phase
		_ = method
		_ = path
		_ = appKey
	}})

	_, _, _ = hook.ResolveRateLimitRule(context.Background(), ratelimit.Lookup{Service: "order-api", Phase: "pre_auth", Method: "GET", Path: "/orders"})
	if gotService != "order-api" {
		t.Fatalf("service = %q, want order-api", gotService)
	}
}

func TestNormalizeRateLimitLookup(t *testing.T) {
	lookup, ok := normalizeRateLimitLookup(" order-api ", " POST_AUTH ", " get ", " /orders ", " app-1 ")
	if !ok {
		t.Fatal("expected normalized lookup to be valid")
	}
	if lookup.Service != "order-api" || lookup.Phase != "post_auth" || lookup.Method != "GET" || lookup.Path != "/orders" || lookup.AppKey != "app-1" {
		t.Fatalf("unexpected normalized lookup: %+v", lookup)
	}
}

func TestNormalizeRateLimitLookupRejectsBlankRequiredFields(t *testing.T) {
	if _, ok := normalizeRateLimitLookup("", "pre_auth", "GET", "/orders", "app-1"); ok {
		t.Fatal("expected blank service to be rejected")
	}
	if _, ok := normalizeRateLimitLookup("order-api", "", "GET", "/orders", "app-1"); ok {
		t.Fatal("expected blank phase to be rejected")
	}
	if _, ok := normalizeRateLimitLookup("order-api", "pre_auth", "", "/orders", "app-1"); ok {
		t.Fatal("expected blank method to be rejected")
	}
	if _, ok := normalizeRateLimitLookup("order-api", "pre_auth", "GET", "", "app-1"); ok {
		t.Fatal("expected blank path to be rejected")
	}
}

func TestMapRateLimitRuleRecordCopiesKeyBySlice(t *testing.T) {
	record := &RateLimitRuleRecord{
		Enabled: true,
		KeyBy:   []string{"ip"},
	}
	cfg := mapRateLimitRuleRecord(record)
	if cfg == nil {
		t.Fatal("expected config to be mapped")
	}
	record.KeyBy[0] = "mutated"
	if cfg.KeyBy[0] != "ip" {
		t.Fatalf("expected mapped key_by to be copied, got %v", cfg.KeyBy)
	}
}

func TestRateLimitRuleRepositoryPrefersFallbackExactBeforePattern(t *testing.T) {
	q := &stubRateLimitRuleQuerier{
		exactAppKeyErr:   pgx.ErrNoRows,
		exactFallbackRow: &gen.GetRateLimitExactRuleFallbackRow{Enabled: true, KeyBy: []string{"ip"}, Strategy: "fixed_window", WindowSeconds: 60, MaxRequests: 20, RequestsPerSecond: 20, Burst: 20, ClientTtlSeconds: 300},
		patternAppKeyRow: &gen.GetRateLimitPatternRuleByAppKeyRow{Enabled: true, KeyBy: []string{"ak_path"}, Strategy: "fixed_window", WindowSeconds: 60, MaxRequests: 5, RequestsPerSecond: 5, Burst: 10, ClientTtlSeconds: 300},
	}
	repo := &RateLimitRuleRepository{q: q}

	rule, err := repo.FindRule(context.Background(), "order-api", "post_auth", "GET", "/v1/orders", "app-1")
	if err != nil {
		t.Fatalf("FindRule error: %v", err)
	}
	if rule == nil || rule.MaxRequests != 20 {
		t.Fatalf("unexpected rule: %+v", rule)
	}
	if got := q.calls; len(got) != 2 || got[0] != "exact_app" || got[1] != "exact_fallback" {
		t.Fatalf("unexpected query order: %v", got)
	}
	for _, service := range q.seenServices {
		if service != "order-api" {
			t.Fatalf("unexpected service namespace: %v", q.seenServices)
		}
	}
}

func TestRateLimitRuleRepositoryFallsBackToPatternLookup(t *testing.T) {
	q := &stubRateLimitRuleQuerier{
		exactAppKeyErr:     pgx.ErrNoRows,
		exactFallbackErr:   pgx.ErrNoRows,
		patternAppKeyRow:   &gen.GetRateLimitPatternRuleByAppKeyRow{Enabled: true, KeyBy: []string{"ak_path"}, Strategy: "fixed_window", WindowSeconds: 60, MaxRequests: 8, RequestsPerSecond: 8, Burst: 16, ClientTtlSeconds: 300},
		patternFallbackErr: pgx.ErrNoRows,
	}
	repo := &RateLimitRuleRepository{q: q}

	rule, err := repo.FindRule(context.Background(), "order-api", "post_auth", "GET", "/v1/orders/123", "app-1")
	if err != nil {
		t.Fatalf("FindRule error: %v", err)
	}
	if rule == nil || rule.MaxRequests != 8 {
		t.Fatalf("unexpected rule: %+v", rule)
	}
	if got := q.calls; len(got) != 3 || got[0] != "exact_app" || got[1] != "exact_fallback" || got[2] != "pattern_app" {
		t.Fatalf("unexpected query order: %v", got)
	}
}

func TestRateLimitRuleRepositoryReturnsNilWhenNoRuleMatches(t *testing.T) {
	q := &stubRateLimitRuleQuerier{
		exactFallbackErr:   pgx.ErrNoRows,
		patternFallbackErr: pgx.ErrNoRows,
	}
	repo := &RateLimitRuleRepository{q: q}

	rule, err := repo.FindRule(context.Background(), "order-api", "pre_auth", "GET", "/v1/unknown", "")
	if err != nil {
		t.Fatalf("FindRule error: %v", err)
	}
	if rule != nil {
		t.Fatalf("expected nil rule, got %+v", rule)
	}
	if got := q.calls; len(got) != 2 || got[0] != "exact_fallback" || got[1] != "pattern_fallback" {
		t.Fatalf("unexpected query order: %v", got)
	}
}
