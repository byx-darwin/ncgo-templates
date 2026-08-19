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

type UserHandler struct {
	rbacCli *rbacclient.Client
}

func NewUserHandler(rbacCli *rbacclient.Client) *UserHandler {
	return &UserHandler{rbacCli: rbacCli}
}

func (h *UserHandler) List(ctx context.Context, c *app.RequestContext) {
	resp, err := h.rbacCli.RBACService().ListUsers(ctx, &api.ListUsersRequest{})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Users)
}

func (h *UserHandler) Get(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	resp, err := h.rbacCli.RBACService().GetUser(ctx, &api.GetUserRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.User)
}

func (h *UserHandler) Create(ctx context.Context, c *app.RequestContext) {
	var req api.CreateUserRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rbacCli.RBACService().CreateUser(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.User)
}

func (h *UserHandler) Update(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	var req api.UpdateUserRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	req.Id = id

	resp, err := h.rbacCli.RBACService().UpdateUser(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.User)
}

func (h *UserHandler) Delete(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	_, err := h.rbacCli.RBACService().DeleteUser(ctx, &api.DeleteUserRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, map[string]string{"status": "deleted"})
}
