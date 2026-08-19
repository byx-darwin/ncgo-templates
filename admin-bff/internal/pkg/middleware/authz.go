package middleware

import (
	"context"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/rbac/v1"
)

type permissionKey struct{}

// SetPermission stores the required permission in the request context
func SetPermission(c *app.RequestContext, code string) {
	c.Set("permission", code)
}

// GetPermission retrieves the required permission from the request context
func GetPermission(c *app.RequestContext) string {
	val, exists := c.Get("permission")
	if !exists {
		return ""
	}
	code, _ := val.(string)
	return code
}

// RequirePermission sets the required permission for a route
func RequirePermission(code string) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		SetPermission(c, code)
		c.Next(ctx)
	}
}

// Authz returns an authorization middleware that checks permissions via RBAC service
func Authz(rbacCli *rbacclient.Client) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		perm := GetPermission(c)
		if perm == "" {
			c.Next(ctx)
			return
		}

		claims, ok := GetClaims(c)
		if !ok {
			response.ErrorCode(c, response.CodeUnauthorized)
			c.Abort()
			return
		}

		resp, err := rbacCli.RBACService().Enforce(ctx, &api.EnforceRequest{
			Sub: claims.UUID,
			Obj: perm,
			Act: "execute",
		})
		if err != nil {
			response.ErrorCode(c, response.CodeInternalError)
			c.Abort()
			return
		}

		if !resp.Allowed {
			response.ErrorCode(c, response.CodeForbidden)
			c.Abort()
			return
		}

		c.Next(ctx)
	}
}
