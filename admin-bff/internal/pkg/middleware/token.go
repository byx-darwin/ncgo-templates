package middleware

import (
	"context"
	"errors"
	"strings"

	goerror "github.com/byx-darwin/go-tools/go-common/error"
	"github.com/cloudwego/hertz/pkg/app"
	"github.com/golang-jwt/jwt/v5"

	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/base/conf"
	"github.com/byx-darwin/ncgo-templates/admin-bff-hertz/internal/pkg/response"
)

const ContextKeyTokenClaims = "tokenClaims"

type Claims struct {
	UserID string `json:"user_id"`
	UUID   string `json:"uuid"`
	AK     string `json:"ak"`
	jwt.RegisteredClaims
}

type TokenVerifier interface {
	VerifyToken(ctx context.Context, token string) (*Claims, error)
}

type JWTVerifier struct {
	Config conf.TokenConfig
}

func JWTAuth(cfg conf.TokenConfig) app.HandlerFunc {
	return TokenAuth(cfg, JWTVerifier{Config: cfg})
}

func TokenAuth(cfg conf.TokenConfig, verifier TokenVerifier) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		if !cfg.Enabled {
			c.Next(ctx)
			return
		}
		header := cfg.Header
		if header == "" {
			header = "X-Authorization"
		}
		token := strings.TrimSpace(c.Request.Header.Get(header))
		if strings.HasPrefix(strings.ToLower(token), "bearer ") {
			token = strings.TrimSpace(token[7:])
		}
		if token == "" {
			abort(c, response.CodeTokenMissing)
			return
		}
		claims, err := verifier.VerifyToken(ctx, token)
		if err != nil {
			code, _ := response.CodeMsg(err)
			abort(c, code)
			return
		}
		c.Set(ContextKeyTokenClaims, claims)
		c.Next(ctx)
	}
}

func (v JWTVerifier) VerifyToken(ctx context.Context, tokenString string) (*Claims, error) {
	_ = ctx
	if v.Config.SigningKey == "" {
		return nil, goerror.In("token").Code(response.CodeConfigInvalid).Public(response.MsgFromCode(response.CodeConfigInvalid)).New("token signing key is empty")
	}
	claims := &Claims{}
	options := make([]jwt.ParserOption, 0, 1)
	if v.Config.Issuer != "" {
		options = append(options, jwt.WithIssuer(v.Config.Issuer))
	}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (any, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).New("invalid token signing method")
		}
		return []byte(v.Config.SigningKey), nil
	}, options...)
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, goerror.In("token").Code(response.CodeTokenExpired).Public(response.MsgFromCode(response.CodeTokenExpired)).Wrap(err)
		}
		if errors.Is(err, jwt.ErrTokenInvalidClaims) || errors.Is(err, jwt.ErrTokenNotValidYet) {
			return nil, goerror.In("token").Code(response.CodeClaimsInvalid).Public(response.MsgFromCode(response.CodeClaimsInvalid)).Wrap(err)
		}
		return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).Wrap(err)
	}
	if token == nil || !token.Valid {
		return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).New("token is invalid")
	}
	return claims, nil
}

func GetClaims(c *app.RequestContext) (*Claims, bool) {
	value, ok := c.Get(ContextKeyTokenClaims)
	if !ok {
		return nil, false
	}
	claims, ok := value.(*Claims)
	return claims, ok
}
