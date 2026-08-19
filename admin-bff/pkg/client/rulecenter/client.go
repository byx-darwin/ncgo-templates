package rulecenter

import (
	"context"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
	rulecenterserviceclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/ratelimit/v1/ruleservice"
	"github.com/cloudwego/kitex/client"
)

// Client wraps rule center service client
type Client struct {
	rule rulecenterserviceclient.Client
}

// New creates a new RuleCenter client wrapper
func New(ctx context.Context, cfg conf.ClientConfig) (*Client, error) {
	ruleCli, err := rulecenterserviceclient.NewClient("rulecenterservice", client.WithHostPorts(cfg.HostPorts...))
	if err != nil {
		return nil, err
	}

	return &Client{
		rule: ruleCli,
	}, nil
}

// RuleService returns the rule service client
func (c *Client) RuleService() rulecenterserviceclient.Client {
	return c.rule
}
