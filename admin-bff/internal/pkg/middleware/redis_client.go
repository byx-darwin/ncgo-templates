package middleware

import "github.com/redis/go-redis/v9"

func sharedRedisClient(cfg any) redis.UniversalClient { return nil }
