package health

import (
	"context"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
)

type Body struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}

func Register(h *server.Hertz) {
	h.GET("/healthz", Healthz)
	h.GET("/readyz", Readyz)
}

func Healthz(ctx context.Context, c *app.RequestContext) {
	_ = ctx
	response.OK(c, Body{Status: "ok", Time: time.Now().UTC().Format(time.RFC3339)})
}

func Readyz(ctx context.Context, c *app.RequestContext) {
	_ = ctx
	response.OK(c, Body{Status: "ready", Time: time.Now().UTC().Format(time.RFC3339)})
}
