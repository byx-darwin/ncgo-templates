package handler

import (
	"context"
	"encoding/json"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/middleware"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rbacclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rbac"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/auth/v1"
)

type AuthHandler struct {
	rbacCli *rbacclient.Client
}

func NewAuthHandler(rbacCli *rbacclient.Client) *AuthHandler {
	return &AuthHandler{rbacCli: rbacCli}
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (h *AuthHandler) Login(ctx context.Context, c *app.RequestContext) {
	var req LoginRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rbacCli.AuthService().Login(ctx, &api.LoginRequest{
		Username: req.Username,
		Password: req.Password,
	})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}

	response.OK(c, map[string]interface{}{
		"access_token":  resp.AccessToken,
		"refresh_token": resp.RefreshToken,
		"expires_in":    resp.ExpiresIn,
	})
}

func (h *AuthHandler) Refresh(ctx context.Context, c *app.RequestContext) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rbacCli.AuthService().Refresh(ctx, &api.RefreshRequest{
		RefreshToken: req.RefreshToken,
	})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}

	response.OK(c, map[string]interface{}{
		"access_token":  resp.AccessToken,
		"refresh_token": resp.RefreshToken,
		"expires_in":    resp.ExpiresIn,
	})
}

func (h *AuthHandler) Logout(ctx context.Context, c *app.RequestContext) {
	claims, ok := middleware.GetClaims(c)
	if !ok {
		response.ErrorCode(c, response.CodeUnauthorized)
		return
	}

	_, err := h.rbacCli.AuthService().Logout(ctx, &api.LogoutRequest{
		UserId: claims.UUID,
	})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}

	response.OK(c, map[string]string{"status": "ok"})
}
