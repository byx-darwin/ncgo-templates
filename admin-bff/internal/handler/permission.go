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

type PermissionHandler struct {
	rbacCli *rbacclient.Client
}

func NewPermissionHandler(rbacCli *rbacclient.Client) *PermissionHandler {
	return &PermissionHandler{rbacCli: rbacCli}
}

func (h *PermissionHandler) List(ctx context.Context, c *app.RequestContext) {
	resp, err := h.rbacCli.RBACService().ListPermissions(ctx, &api.ListPermissionsRequest{})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Permissions)
}

func (h *PermissionHandler) Get(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	resp, err := h.rbacCli.RBACService().GetPermission(ctx, &api.GetPermissionRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Permission)
}

func (h *PermissionHandler) Create(ctx context.Context, c *app.RequestContext) {
	var req api.CreatePermissionRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rbacCli.RBACService().CreatePermission(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Permission)
}

func (h *PermissionHandler) Update(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	var req api.UpdatePermissionRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	req.Id = id

	resp, err := h.rbacCli.RBACService().UpdatePermission(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Permission)
}

func (h *PermissionHandler) Delete(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	_, err := h.rbacCli.RBACService().DeletePermission(ctx, &api.DeletePermissionRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, map[string]string{"status": "deleted"})
}
