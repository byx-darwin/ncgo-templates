package server

import (
    "context"
    "log"

    "time"

    "github.com/samber/do"


    hertzframework "github.com/byx-darwin/go-tools/go-framework/hertz"
    gfconfig "github.com/byx-darwin/go-tools/go-framework/config"
    hertzobs "github.com/byx-darwin/go-tools/go-framework/hertz/observability"

    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"

    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/data"
    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/repository"

    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/middleware"
    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
    "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/router"
    rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
    rulecenterclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rulecenter"
)

func Run() {
    cfg := conf.Get()

    // ncgo:wire:logging:init
    ctx := context.Background()
    h, err := hertzframework.NewHTTPServer(ctx, &cfg.Server)
    if err != nil {
        log.Fatalf("create server: %v", err)
    }

    // Responder middleware — injects RequestID / Lang / Responder into context
    responder := response.NewResponder()
    h.Use(responder.Middleware())

    // AccessLog middleware — uses go-tools AccessLog
    h.Use(middleware.AccessLog())

    // OTel tracing — enabled when server.jaeger config is present
    if cfg.Server.Jaeger != nil && cfg.Server.Jaeger.Enable {
        provider, obsErr := hertzobs.NewProvider(ctx, gfconfig.ObservabilityConfig{
            Enabled:     true,
            Endpoint:    cfg.Server.Jaeger.Endpoint,
            ServiceName: cfg.Server.Registry.Name,
        })
        if obsErr != nil {
            log.Fatalf("init observability: %v", obsErr)
        }
        defer func() {
            if shutdownErr := provider.Shutdown(); shutdownErr != nil {
                log.Printf("shutdown observability: %v", shutdownErr)
            }
        }()
        h.Use(provider.ServerMiddleware())
    }

    // Optional structured logging wiring (after `ncgo add infra logging`):
    // import "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/logging"
    // ncgo:wire:logging:server-middleware
    // h.Use(logging.HertzRecovery())
    // h.Use(logging.HertzRequestID())
    // h.Use(logging.HertzAccessLog())

    // Optional release canary wiring (after `ncgo add infra canary`):
    // import "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/release"
    // ncgo:wire:canary:server-traffic
    // if cfg.Release.Enabled {
    //     h.Use(release.HertzTraffic())
    // }

    // ncgo:wire:ddd — Wire DDD layers (data -> repository -> usecase)
    
    if cfg.Database.Enabled {
        injector := do.New()

        startupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()

        pgCfg, err := data.NewPostgresConfigFromDatabase(cfg.Database)
        if err != nil {
            log.Fatalf("database config: %v", err)
        }

        pool, err := data.NewPostgres(startupCtx, pgCfg)
        if err != nil {
            log.Fatalf("connect database: %v", err)
        }

        dbData, cleanup, err := data.New(pool)
        if err != nil {
            log.Fatalf("init data: %v", err)
        }
        defer cleanup()

        do.ProvideValue[context.Context](injector, startupCtx)
        do.ProvideValue(injector, pool)
        do.ProvideValue(injector, dbData)

        dbData = do.MustInvoke[*data.Data](injector)
        repository.NewRateLimitRuleRepository(dbData)
    }


    // Initialize RPC clients for admin BFF
    rbacCli, err := rbacclient.New(ctx, cfg.GRPC.RBAC)
    if err != nil {
        log.Fatalf("init rbac client: %v", err)
    }

    rulecenterCli, err := rulecenterclient.New(ctx, cfg.GRPC.RuleCenter)
    if err != nil {
        log.Fatalf("init rulecenter client: %v", err)
    }

    // Register routes
    router.GeneratedRegister(h)
    router.RegisterAdminRoutes(h, rbacCli, rulecenterCli)

    // Start server
    h.Spin()
}