package conf

import "testing"

func TestApplyRedisFallbacksUsesTopLevelRedis(t *testing.T) {
	cfg := &Config{
		Redis:       RedisConfig{Addrs: []string{"redis-shared:6379"}, PoolSize: 20, ClientName: "shared"},
		RateLimit:   RateLimitConfig{Backend: "redis"},
		Idempotency: IdempotencyConfig{Backend: "redis"},
		Auth:        AuthConfig{Signature: SignatureConfig{Nonce: SignatureNonceConfig{Enabled: true, Backend: "redis"}}},
	}
	cfg.applyRedisFallbacks()
	for name, got := range map[string]RedisConfig{
		"rate_limit":      cfg.RateLimit.Redis,
		"idempotency":     cfg.Idempotency.Redis,
		"signature_nonce": cfg.Auth.Signature.Nonce.Redis,
	} {
		if len(got.Addrs) != 1 || got.Addrs[0] != "redis-shared:6379" {
			t.Fatalf("%s addrs = %v, want shared redis", name, got.Addrs)
		}
		if got.PoolSize != 20 || got.ClientName != "shared" {
			t.Fatalf("%s redis fallback = %+v", name, got)
		}
	}
}

func TestValidateAppliesRedisFallbacks(t *testing.T) {
	cfg := Default()
	cfg.Redis.Addrs = []string{"redis-top:6379"}
	cfg.Redis.PoolSize = 32
	cfg.RateLimit.Enabled = true
	cfg.RateLimit.Backend = "redis"
	cfg.RateLimit.Redis = RedisConfig{Addrs: []string{"redis-rate:6379"}}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(cfg.RateLimit.Redis.Addrs) != 1 || cfg.RateLimit.Redis.Addrs[0] != "redis-rate:6379" {
		t.Fatalf("rate_limit addrs = %v, want module override", cfg.RateLimit.Redis.Addrs)
	}
	if cfg.RateLimit.Redis.PoolSize != 32 {
		t.Fatalf("rate_limit pool_size = %d, want inherited top-level pool size", cfg.RateLimit.Redis.PoolSize)
	}
}
