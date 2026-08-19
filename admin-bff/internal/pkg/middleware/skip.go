package middleware

import (
	"context"
	"net"
	"strings"

	"github.com/cloudwego/hertz/pkg/app"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
)

type Skipper func(ctx context.Context, c *app.RequestContext) bool

func Unless(handler app.HandlerFunc, skipper Skipper) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		if skipper != nil && skipper(ctx, c) {
			c.Next(ctx)
			return
		}
		handler(ctx, c)
	}
}

func PathSkipper(paths ...string) Skipper {
	allowed := make(map[string]struct{}, len(paths))
	prefixes := make([]string, 0, len(paths))
	for _, path := range paths {
		if path != "" {
			if strings.HasSuffix(path, "*") {
				prefixes = append(prefixes, strings.TrimSuffix(path, "*"))
				continue
			}
			allowed[path] = struct{}{}
		}
	}
	return func(ctx context.Context, c *app.RequestContext) bool {
		_ = ctx
		currentPath := string(c.Path())
		if _, ok := allowed[currentPath]; ok {
			return true
		}
		for _, prefix := range prefixes {
			if strings.HasPrefix(currentPath, prefix) {
				return true
			}
		}
		return false
	}
}

func InternalOnly(paths []string, cidrs []string) app.HandlerFunc {
	pathSkipper := PathSkipper(paths...)
	networks := parseCIDRs(cidrs)
	return func(ctx context.Context, c *app.RequestContext) {
		if !pathSkipper(ctx, c) {
			c.Next(ctx)
			return
		}
		ip := remoteIP(c)
		for _, network := range networks {
			if network.Contains(ip) {
				c.Next(ctx)
				return
			}
		}
		response.ErrorCode(c, response.CodePermissionDenied)
		c.Abort()
	}
}

func parseCIDRs(cidrs []string) []*net.IPNet {
	networks := make([]*net.IPNet, 0, len(cidrs))
	for _, cidr := range cidrs {
		_, network, err := net.ParseCIDR(strings.TrimSpace(cidr))
		if err != nil {
			panic("middleware: invalid internal CIDR " + cidr)
		}
		networks = append(networks, network)
	}
	return networks
}

func remoteIP(c *app.RequestContext) net.IP {
	if addr := c.RemoteAddr(); addr != nil {
		host, _, err := net.SplitHostPort(addr.String())
		if err == nil {
			return net.ParseIP(host)
		}
		return net.ParseIP(addr.String())
	}
	return nil
}
