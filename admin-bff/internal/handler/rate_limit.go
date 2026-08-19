package handler

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
	rulecenterclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/pkg/client/rulecenter"
	api "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/ratelimit/v1"
)

type RateLimitHandler struct {
	rulecenterCli *rulecenterclient.Client
}

func NewRateLimitHandler(rulecenterCli *rulecenterclient.Client) *RateLimitHandler {
	return &RateLimitHandler{rulecenterCli: rulecenterCli}
}

func (h *RateLimitHandler) List(ctx context.Context, c *app.RequestContext) {
	resp, err := h.rulecenterCli.RuleService().ListRules(ctx, &api.ListRulesRequest{})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Rules)
}

func (h *RateLimitHandler) Create(ctx context.Context, c *app.RequestContext) {
	var req api.CreateRuleRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}

	resp, err := h.rulecenterCli.RuleService().CreateRule(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Rule)
}

func (h *RateLimitHandler) Update(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	var req api.UpdateRuleRequest
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	req.Id = id

	resp, err := h.rulecenterCli.RuleService().UpdateRule(ctx, &req)
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, resp.Rule)
}

func (h *RateLimitHandler) Delete(ctx context.Context, c *app.RequestContext) {
	idStr := c.Param("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)

	_, err := h.rulecenterCli.RuleService().DeleteRule(ctx, &api.DeleteRuleRequest{Id: id})
	if err != nil {
		response.ErrorCode(c, response.CodeInternalError)
		return
	}
	response.OK(c, map[string]string{"status": "deleted"})
}
