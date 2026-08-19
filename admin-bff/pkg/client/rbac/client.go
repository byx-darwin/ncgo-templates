package rbac

import (
	"context"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
	authserviceclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/auth/v1/authservice"
	rbacserviceclient "github.com/byx-darwin/ncgo-templates/admin-bff-hertz/kitex_gen/api/rbac/v1/rbacservice"
	"github.com/cloudwego/kitex/client"
)

// Client wraps auth and rbac service clients
type Client struct {
	auth authserviceclient.Client
	rbac rbacserviceclient.Client
}

// New creates a new RBAC client wrapper
func New(ctx context.Context, cfg conf.ClientConfig) (*Client, error) {
	authCli, err := authserviceclient.NewClient("authservice", client.WithHostPorts(cfg.HostPorts...))
	if err != nil {
		return nil, err
	}

	rbacCli, err := rbacserviceclient.NewClient("rbacservice", client.WithHostPorts(cfg.HostPorts...))
	if err != nil {
		return nil, err
	}

	return &Client{
		auth: authCli,
		rbac: rbacCli,
	}, nil
}

// AuthService returns the auth service client
func (c *Client) AuthService() authserviceclient.Client {
	return c.auth
}

// RBACService returns the rbac service client
func (c *Client) RBACService() rbacserviceclient.Client {
	return c.rbac
}
