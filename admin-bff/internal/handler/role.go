package handler

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/rbac/v1"
)

type RoleHandler struct {
	rbacCli *rbacclient.Client
}

func NewRoleHandler(rbacCli *rbacclient.Client) *RoleHandler {
	return &RoleHandler{rbacCli: rbacCli}
}

func (h *RoleHandler) List(ctx context.Context, c *app.RequestContext) {
	resp, err := h.rbacCli.RBACService().ListRoles(ctx, &api.ListRolesRequest{})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Roles)
}

func (h *RoleHandler) Create(ctx context.Context, c *app.RequestContext) {
	var req api.CreateRoleRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rbacCli.RBACService().CreateRole(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Role)
}

func (h *RoleHandler) Update(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	var req api.UpdateRoleRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	req.Id = id

	resp, err := h.rbacCli.RBACService().UpdateRole(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Role)
}

func (h *RoleHandler) Delete(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	_, err := h.rbacCli.RBACService().DeleteRole(ctx, &api.DeleteRoleRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, map[string]string{"status": "deleted"})
}
