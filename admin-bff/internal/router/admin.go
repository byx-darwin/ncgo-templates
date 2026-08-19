package router

import (
	"github.com/cloudwego/hertz/pkg/app/server"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/handler"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/middleware"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	rulecenterclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rulecenter"
)

// RegisterAdminRoutes registers all admin BFF routes
func RegisterAdminRoutes(h *server.Hertz, rbacCli *rbacclient.Client, rulecenterCli *rulecenterclient.Client) {
	cfg := conf.Get()

	authHandler := handler.NewAuthHandler(rbacCli)
	userHandler := handler.NewUserHandler(rbacCli)
	roleHandler := handler.NewRoleHandler(rbacCli)
	permHandler := handler.NewPermissionHandler(rbacCli)
	menuHandler := handler.NewMenuHandler(rbacCli)
	currentUserHandler := handler.NewCurrentUserHandler(rbacCli)
	rateLimitHandler := handler.NewRateLimitHandler(rulecenterCli)

	api := h.Group("/api/v1")

	// Public routes (no JWT)
	auth := api.Group("/auth")
	auth.POST("/login", authHandler.Login)
	auth.POST("/refresh", authHandler.Refresh)

	// Protected routes (JWT required)
	protected := api.Group("")
	protected.Use(middleware.JWT(cfg.JWT.Secret))

	// Authz middleware
	protected.Use(middleware.Authz(rbacCli))

	// Auth (logout requires auth)
	protected.POST("/auth/logout", authHandler.Logout)

	// Current user
	me := protected.Group("/me")
	me.GET("/menus", currentUserHandler.GetMenus)
	me.GET("/perms", currentUserHandler.GetPerms)

	// RBAC management
	users := protected.Group("/users")
	users.GET("", middleware.RequirePermission("user:list"), userHandler.List)
	users.GET("/:id", middleware.RequirePermission("user:read"), userHandler.Get)
	users.POST("", middleware.RequirePermission("user:create"), userHandler.Create)
	users.PUT("/:id", middleware.RequirePermission("user:update"), userHandler.Update)
	users.DELETE("/:id", middleware.RequirePermission("user:delete"), userHandler.Delete)

	roles := protected.Group("/roles")
	roles.GET("", middleware.RequirePermission("role:list"), roleHandler.List)
	roles.POST("", middleware.RequirePermission("role:create"), roleHandler.Create)
	roles.PUT("/:id", middleware.RequirePermission("role:update"), roleHandler.Update)
	roles.DELETE("/:id", middleware.RequirePermission("role:delete"), roleHandler.Delete)

	perms := protected.Group("/permissions")
	perms.GET("", middleware.RequirePermission("permission:list"), permHandler.List)
	perms.GET("/:id", middleware.RequirePermission("permission:read"), permHandler.Get)
	perms.POST("", middleware.RequirePermission("permission:create"), permHandler.Create)
	perms.PUT("/:id", middleware.RequirePermission("permission:update"), permHandler.Update)
	perms.DELETE("/:id", middleware.RequirePermission("permission:delete"), permHandler.Delete)

	menus := protected.Group("/menus")
	menus.GET("", middleware.RequirePermission("menu:list"), menuHandler.List)

	// Rate limit rules
	rules := protected.Group("/rate-limit-rules")
	rules.GET("", middleware.RequirePermission("rate_limit:list"), rateLimitHandler.List)
	rules.POST("", middleware.RequirePermission("rate_limit:create"), rateLimitHandler.Create)
	rules.PUT("/:id", middleware.RequirePermission("rate_limit:update"), rateLimitHandler.Update)
	rules.DELETE("/:id", middleware.RequirePermission("rate_limit:delete"), rateLimitHandler.Delete)
}
