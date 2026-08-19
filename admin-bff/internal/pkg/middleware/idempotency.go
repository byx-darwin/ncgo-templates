package middleware

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"
	"time"

	config "github.com/byx-darwin/go-tools/go-framework/config"
	"github.com/cloudwego/hertz/pkg/app"
	"github.com/redis/go-redis/v9"
	"github.com/samber/hot"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
)

const (
	idempotencyStateProcessing = "processing"
	idempotencyStateCompleted  = "completed"
	headerIdempotencyReplayed  = "X-Idempotency-Replayed"
)

type idempotencyRecord struct {
	State       string `json:"state"`
	Status      int    `json:"status,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	Body        []byte `json:"body,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	ExpiresAt   int64  `json:"expires_at"`
}

type idempotencyStore interface {
	Begin(ctx context.Context, key string, fingerprint string, ttl time.Duration) (*idempotencyRecord, bool, error)
	Complete(ctx context.Context, key string, record idempotencyRecord, ttl time.Duration) error
	Release(ctx context.Context, key string) error
}

type memoryIdempotencyStore struct {
	mu     sync.Mutex
	values *hot.HotCache[string, idempotencyRecord]
}

type redisIdempotencyStore struct {
	client redis.UniversalClient
}

func Idempotency(cfg conf.IdempotencyConfig) app.HandlerFunc {
	cfg = normalizeIdempotencyConfig(cfg)
	skipper := PathSkipper(cfg.SkipPaths...)
	methods := idempotencyMethods(cfg.Methods)
	store := newIdempotencyStore(cfg)
	ttl := cfg.TTLSeconds.Duration
	return func(ctx context.Context, c *app.RequestContext) {
		if !cfg.Enabled || skipper(ctx, c) || !methods[string(c.Method())] {
			c.Next(ctx)
			return
		}
		requestKey := strings.TrimSpace(c.Request.Header.Get(cfg.Header))
		if requestKey == "" {
			response.ErrorCode(c, response.CodeIdempotencyKeyMissing)
			c.Abort()
			return
		}
		key := idempotencyKey(c, cfg, requestKey)
		fingerprint := idempotencyFingerprint(c)
		existing, acquired, err := store.Begin(ctx, key, fingerprint, ttl)
		if err != nil {
			if cfg.FailOpen {
				c.Next(ctx)
				return
			}
			response.ErrorCode(c, response.CodeCacheUnavailable)
			c.Abort()
			return
		}
		if !acquired {
			if existing != nil && existing.Fingerprint != "" && existing.Fingerprint != fingerprint {
				response.ErrorCode(c, response.CodeIdempotencyConflict)
				c.Abort()
				return
			}
			if existing != nil && existing.State == idempotencyStateCompleted {
				replayIdempotencyResponse(c, *existing)
				c.Abort()
				return
			}
			response.ErrorCode(c, response.CodeDuplicateRequest)
			c.Abort()
			return
		}

		c.Next(ctx)

		status := c.Response.StatusCode()
		body := append([]byte(nil), c.Response.Body()...)
		if !idempotencyCacheableStatus(status) || (cfg.MaxBodyBytes > 0 && len(body) > cfg.MaxBodyBytes) {
			_ = store.Release(ctx, key)
			return
		}
		record := idempotencyRecord{
			State:       idempotencyStateCompleted,
			Status:      status,
			ContentType: string(c.Response.Header.ContentType()),
			Body:        body,
			Fingerprint: fingerprint,
			ExpiresAt:   time.Now().Add(ttl).Unix(),
		}
		if err := store.Complete(ctx, key, record, ttl); err != nil && !cfg.FailOpen {
			response.ErrorCode(c, response.CodeCacheUnavailable)
			c.Abort()
			return
		}
	}
}

func newIdempotencyStore(cfg conf.IdempotencyConfig) idempotencyStore {
	if cfg.Backend == "redis" {
		return &redisIdempotencyStore{client: sharedRedisClient(cfg.Redis)}
	}
	return newMemoryIdempotencyStore(cfg.Memory.MaxEntries)
}

func newMemoryIdempotencyStore(maxEntries int) *memoryIdempotencyStore {
	return &memoryIdempotencyStore{values: hot.NewHotCache[string, idempotencyRecord](hot.LRU, memoryCacheMaxEntries(maxEntries)).Build()}
}

func (s *memoryIdempotencyStore) Begin(ctx context.Context, key string, fingerprint string, ttl time.Duration) (*idempotencyRecord, bool, error) {
	_ = ctx
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	now := time.Now()
	expiresAt := now.Add(ttl)
	s.mu.Lock()
	defer s.mu.Unlock()
	if record, found, err := s.values.Get(key); err != nil {
		return nil, false, err
	} else if found {
		if record.ExpiresAt > now.Unix() {
			copied := cloneIdempotencyRecord(record)
			return &copied, false, nil
		}
		s.values.Delete(key)
	}
	s.values.SetWithTTL(key, idempotencyRecord{State: idempotencyStateProcessing, Fingerprint: fingerprint, ExpiresAt: expiresAt.Unix()}, ttl)
	return nil, true, nil
}

func (s *memoryIdempotencyStore) Complete(ctx context.Context, key string, record idempotencyRecord, ttl time.Duration) error {
	_ = ctx
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	record.ExpiresAt = time.Now().Add(ttl).Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.values.SetWithTTL(key, cloneIdempotencyRecord(record), ttl)
	return nil
}

func (s *memoryIdempotencyStore) Release(ctx context.Context, key string) error {
	_ = ctx
	s.mu.Lock()
	defer s.mu.Unlock()
	s.values.Delete(key)
	return nil
}

func (s *redisIdempotencyStore) Begin(ctx context.Context, key string, fingerprint string, ttl time.Duration) (*idempotencyRecord, bool, error) {
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	payload, _ := json.Marshal(idempotencyRecord{State: idempotencyStateProcessing, Fingerprint: fingerprint, ExpiresAt: time.Now().Add(ttl).Unix()})
	ok, err := s.client.SetNX(ctx, key, payload, ttl).Result()
	if err != nil {
		return nil, false, err
	}
	if ok {
		return nil, true, nil
	}
	value, err := s.client.Get(ctx, key).Bytes()
	if err == redis.Nil {
		return &idempotencyRecord{State: idempotencyStateProcessing}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	record := idempotencyRecord{}
	if err := json.Unmarshal(value, &record); err != nil {
		return nil, false, err
	}
	return &record, false, nil
}

func (s *redisIdempotencyStore) Complete(ctx context.Context, key string, record idempotencyRecord, ttl time.Duration) error {
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	record.ExpiresAt = time.Now().Add(ttl).Unix()
	payload, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return s.client.Set(ctx, key, payload, ttl).Err()
}

func (s *redisIdempotencyStore) Release(ctx context.Context, key string) error {
	return s.client.Del(ctx, key).Err()
}

func replayIdempotencyResponse(c *app.RequestContext, record idempotencyRecord) {
	if record.Status <= 0 {
		record.Status = response.StatusFromCode(response.CodeDuplicateRequest)
	}
	c.Response.SetStatusCode(record.Status)
	if record.ContentType != "" {
		c.Response.Header.SetContentType(record.ContentType)
	}
	c.Response.Header.Set(headerIdempotencyReplayed, "true")
	c.Response.SetBody(record.Body)
}

func idempotencyKey(c *app.RequestContext, cfg conf.IdempotencyConfig, requestKey string) string {
	scope := "ip:" + requestIP(c)
	if claims, ok := GetClaims(c); ok {
		switch {
		case claims.AK != "" && claims.UUID != "":
			scope = "ak_user_uuid:" + claims.AK + ":" + claims.UUID
		case claims.UUID != "":
			scope = "user_uuid:" + claims.UUID
		case claims.AK != "":
			scope = "ak:" + claims.AK
		}
	} else if ak := strings.TrimSpace(c.Request.Header.Get(cfg.AppKeyHeader)); ak != "" {
		scope = "ak:" + ak
	}
	return joinRateLimitKey(cfg.KeyPrefix, scope, string(c.Method()), string(c.Path()), requestKey)
}

func idempotencyFingerprint(c *app.RequestContext) string {
	hash := sha256.New()
	_, _ = hash.Write(c.Method())
	_, _ = hash.Write([]byte("\n"))
	_, _ = hash.Write(c.Path())
	_, _ = hash.Write([]byte("\n"))
	_, _ = hash.Write(c.Request.URI().QueryString())
	_, _ = hash.Write([]byte("\n"))
	_, _ = hash.Write(c.Request.Body())
	return hex.EncodeToString(hash.Sum(nil))
}

func idempotencyMethods(values []string) map[string]bool {
	if len(values) == 0 {
		values = []string{"POST", "PUT", "PATCH", "DELETE"}
	}
	out := make(map[string]bool, len(values))
	for _, value := range values {
		value = strings.ToUpper(strings.TrimSpace(value))
		if value != "" {
			out[value] = true
		}
	}
	return out
}

func idempotencyCacheableStatus(status int) bool {
	return status >= 200 && status < 300
}

func cloneIdempotencyRecord(record idempotencyRecord) idempotencyRecord {
	record.Body = append([]byte(nil), record.Body...)
	return record
}

func normalizeIdempotencyConfig(cfg conf.IdempotencyConfig) conf.IdempotencyConfig {
	if cfg.Backend == "" {
		cfg.Backend = "memory"
	}
	if cfg.Header == "" {
		cfg.Header = "X-Idempotency-Key"
	}
	if cfg.AppKeyHeader == "" {
		cfg.AppKeyHeader = "X-App-Key"
	}
	if cfg.KeyPrefix == "" {
		cfg.KeyPrefix = "idempotency"
	}
	if cfg.TTLSeconds.Duration <= 0 {
		cfg.TTLSeconds = config.Duration{Duration: 86400 * time.Second}
	}
	if cfg.MaxBodyBytes <= 0 {
		cfg.MaxBodyBytes = 1048576
	}
	if cfg.Memory.MaxEntries <= 0 {
		cfg.Memory.MaxEntries = defaultMemoryCacheMaxEntries
	}
	if cfg.Backend == "redis" && len(cfg.Redis.Addrs) == 0 {
		cfg.Redis.Addrs = []string{"127.0.0.1:6379"}
	}
	return cfg
}
