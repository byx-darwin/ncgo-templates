package handler

import (
	"context"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/middleware"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/rbac/v1"
)

type CurrentUserHandler struct {
	rbacCli *rbacclient.Client
}

func NewCurrentUserHandler(rbacCli *rbacclient.Client) *CurrentUserHandler {
	return &CurrentUserHandler{rbacCli: rbacCli}
}

func (h *CurrentUserHandler) GetMenus(ctx context.Context, c *app.RequestContext) {
	claims, ok := middleware.GetClaims(c)
	if !ok {
		response.ErrorCode(c, response.CodeUnauthorized)
		return
	}

	resp, err := h.rbacCli.RBACService().GetUserMenuTree(ctx, &api.GetUserMenuTreeRequest{
		UserId: claims.UUID,
	})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}

	response.OK(c, resp.Menus)
}

func (h *CurrentUserHandler) GetPerms(ctx context.Context, c *app.RequestContext) {
	claims, ok := middleware.GetClaims(c)
	if !ok {
		response.ErrorCode(c, response.CodeUnauthorized)
		return
	}

	resp, err := h.rbacCli.RBACService().GetUserPermCodes(ctx, &api.GetUserPermCodesRequest{
		UserId: claims.UUID,
	})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}

	response.OK(c, resp.PermCodes)
}
