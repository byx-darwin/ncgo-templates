package middleware

import (
	"context"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/middlewares/server/recovery"
	"github.com/cloudwego/hertz/pkg/common/hlog"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
)

func Recovery() app.HandlerFunc {
	return recovery.Recovery(recovery.WithRecoveryHandler(func(ctx context.Context, c *app.RequestContext, err interface{}, stack []byte) {
		hlog.SystemLogger().CtxErrorf(ctx, "[Recovery] err=%v\nstack=%s", err, stack)
		response.ErrorCode(c, response.CodeInternalError)
		c.Abort()
	}))
}

func NoRoute(ctx context.Context, c *app.RequestContext) {
	_ = ctx
	response.ErrorCode(c, response.CodeRouteNotFound)
}

func NoMethod(ctx context.Context, c *app.RequestContext) {
	_ = ctx
	response.ErrorCode(c, response.CodeMethodNotAllowed)
}
