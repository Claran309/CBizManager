package jwt

import (
	"errors"
	"fmt"
	"strings"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

var (
	ErrEmptySecret             = errors.New("JWT 密钥不能为空")
	ErrEmptyIssuer             = errors.New("JWT 签发者不能为空")
	ErrInvalidTTL              = errors.New("JWT 有效期必须大于零")
	ErrUnexpectedSigningMethod = errors.New("JWT 签名算法不受支持")
	ErrInvalidToken            = errors.New("JWT 无效")
)

// Claims 是访问令牌携带的最小身份与会话信息。
type Claims struct {
	UserID      uint64  `json:"user_id"`
	GroupID     *uint64 `json:"group_id,omitempty"`
	AccountType string  `json:"account_type"`
	SessionID   uint64  `json:"session_id"`
	jwtlib.RegisteredClaims
}

// Manager 负责使用固定的 HS256 算法签发和校验 JWT。
type Manager struct {
	secret []byte
	issuer string
	ttl    time.Duration
}

// NewManager 创建 JWT 管理器，并拒绝不安全的空配置。
func NewManager(secret, issuer string, ttl time.Duration) (*Manager, error) {
	if strings.TrimSpace(secret) == "" {
		return nil, ErrEmptySecret
	}
	if strings.TrimSpace(issuer) == "" {
		return nil, ErrEmptyIssuer
	}
	if ttl <= 0 {
		return nil, ErrInvalidTTL
	}

	return &Manager{
		secret: []byte(secret),
		issuer: issuer,
		ttl:    ttl,
	}, nil
}

// Sign 使用传入时间生成可测试、可复现的令牌时间窗口，并返回实际 UTC 过期时间。
func (m *Manager) Sign(claims Claims, now time.Time) (string, time.Time, error) {
	now = now.UTC()
	expiresAt := now.Add(m.ttl)
	claims.Issuer = m.issuer
	claims.IssuedAt = jwtlib.NewNumericDate(now)
	claims.NotBefore = jwtlib.NewNumericDate(now)
	claims.ExpiresAt = jwtlib.NewNumericDate(expiresAt)

	token := jwtlib.NewWithClaims(jwtlib.SigningMethodHS256, claims)
	raw, err := token.SignedString(m.secret)
	return raw, expiresAt, err
}

// Parse 校验算法、签名、签发者与标准时间声明后返回业务 Claims。
func (m *Manager) Parse(raw string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwtlib.ParseWithClaims(
		raw,
		claims,
		func(token *jwtlib.Token) (any, error) {
			if token.Method != jwtlib.SigningMethodHS256 {
				return nil, fmt.Errorf("%w: %s", ErrUnexpectedSigningMethod, token.Method.Alg())
			}
			return m.secret, nil
		},
		jwtlib.WithValidMethods([]string{jwtlib.SigningMethodHS256.Alg()}),
		jwtlib.WithIssuer(m.issuer),
		jwtlib.WithExpirationRequired(),
		jwtlib.WithIssuedAt(),
	)
	if err != nil {
		return nil, err
	}
	if !token.Valid {
		return nil, ErrInvalidToken
	}
	if claims.IssuedAt == nil || claims.NotBefore == nil {
		return nil, ErrInvalidToken
	}
	return claims, nil
}
