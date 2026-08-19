package handler

import (
	"context"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/rbac/v1"
)

type MenuHandler struct {
	rbacCli *rbacclient.Client
}

func NewMenuHandler(rbacCli *rbacclient.Client) *MenuHandler {
	return &MenuHandler{rbacCli: rbacCli}
}

func (h *MenuHandler) List(ctx context.Context, c *app.RequestContext) {
	resp, err := h.rbacCli.RBACService().ListMenus(ctx, &api.ListMenusRequest{})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Menus)
}
