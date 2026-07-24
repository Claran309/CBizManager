package jwt

import (
	"errors"
	"testing"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

func TestNewManagerRejectsEmptySecret(t *testing.T) {
	if _, err := NewManager("", "cbizdocsmanager", 15*time.Minute); !errors.Is(err, ErrEmptySecret) {
		t.Fatalf("NewManager() error = %v, want ErrEmptySecret", err)
	}
}

func TestManagerSignsAndParsesHS256Claims(t *testing.T) {
	const (
		secret = "a-test-secret-that-is-not-empty"
		issuer = "cbizdocsmanager"
	)
	ttl := 15 * time.Minute
	now := time.Now().In(time.FixedZone("UTC+8", 8*60*60)).Truncate(time.Second)
	groupID := uint64(42)
	manager := mustManager(t, secret, issuer, ttl)

	raw, expiresAt, err := manager.Sign(Claims{
		UserID:      7,
		GroupID:     &groupID,
		AccountType: "group_owner",
		SessionID:   99,
	}, now)
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}
	wantExpiresAt := now.UTC().Add(ttl)
	if expiresAt.Location() != time.UTC {
		t.Fatalf("Sign() expiration location = %v, want UTC", expiresAt.Location())
	}
	if !expiresAt.Equal(wantExpiresAt) {
		t.Fatalf("Sign() expiration = %v, want %v", expiresAt, wantExpiresAt)
	}

	unverified, _, err := jwtlib.NewParser().ParseUnverified(raw, &Claims{})
	if err != nil {
		t.Fatalf("ParseUnverified() error = %v", err)
	}
	if got := unverified.Method.Alg(); got != jwtlib.SigningMethodHS256.Alg() {
		t.Fatalf("signing algorithm = %q, want %q", got, jwtlib.SigningMethodHS256.Alg())
	}

	got, err := manager.Parse(raw)
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if got.UserID != 7 || got.SessionID != 99 || got.AccountType != "group_owner" {
		t.Fatalf("parsed custom claims = %#v", got)
	}
	if got.GroupID == nil || *got.GroupID != groupID {
		t.Fatalf("GroupID = %v, want %d", got.GroupID, groupID)
	}
	if got.Issuer != issuer {
		t.Fatalf("Issuer = %q, want %q", got.Issuer, issuer)
	}
	if got.IssuedAt == nil || !got.IssuedAt.Time.Equal(now) {
		t.Fatalf("IssuedAt = %v, want %v", got.IssuedAt, now)
	}
	if got.NotBefore == nil || !got.NotBefore.Time.Equal(now) {
		t.Fatalf("NotBefore = %v, want %v", got.NotBefore, now)
	}
	if got.ExpiresAt == nil || !got.ExpiresAt.Time.Equal(expiresAt) {
		t.Fatalf("ExpiresAt = %v, want returned expiration %v", got.ExpiresAt, expiresAt)
	}
}

func TestManagerRejectsTokenWithoutExpiration(t *testing.T) {
	const (
		secret = "shared-secret"
		issuer = "cbizdocsmanager"
	)
	manager := mustManager(t, secret, issuer, 15*time.Minute)
	now := time.Now().UTC().Truncate(time.Second)
	raw := mustSignClaims(t, secret, Claims{
		UserID:    1,
		SessionID: 2,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    issuer,
			IssuedAt:  jwtlib.NewNumericDate(now),
			NotBefore: jwtlib.NewNumericDate(now),
		},
	})

	if _, err := manager.Parse(raw); !errors.Is(err, jwtlib.ErrTokenRequiredClaimMissing) {
		t.Fatalf("Parse() error = %v, want jwt.ErrTokenRequiredClaimMissing", err)
	}
}

func TestManagerRejectsTokenWithoutIssuedAt(t *testing.T) {
	const (
		secret = "shared-secret"
		issuer = "cbizdocsmanager"
	)
	manager := mustManager(t, secret, issuer, 15*time.Minute)
	now := time.Now().UTC().Truncate(time.Second)
	raw := mustSignClaims(t, secret, Claims{
		UserID:    1,
		SessionID: 2,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    issuer,
			NotBefore: jwtlib.NewNumericDate(now),
			ExpiresAt: jwtlib.NewNumericDate(now.Add(15 * time.Minute)),
		},
	})

	if _, err := manager.Parse(raw); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("Parse() error = %v, want ErrInvalidToken", err)
	}
}

func TestManagerRejectsTokenWithoutNotBefore(t *testing.T) {
	const (
		secret = "shared-secret"
		issuer = "cbizdocsmanager"
	)
	manager := mustManager(t, secret, issuer, 15*time.Minute)
	now := time.Now().UTC().Truncate(time.Second)
	raw := mustSignClaims(t, secret, Claims{
		UserID:    1,
		SessionID: 2,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    issuer,
			IssuedAt:  jwtlib.NewNumericDate(now),
			ExpiresAt: jwtlib.NewNumericDate(now.Add(15 * time.Minute)),
		},
	})

	if _, err := manager.Parse(raw); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("Parse() error = %v, want ErrInvalidToken", err)
	}
}

func TestManagerRejectsExpiredToken(t *testing.T) {
	manager := mustManager(t, "secret", "cbizdocsmanager", time.Minute)
	raw, _, err := manager.Sign(Claims{UserID: 1, SessionID: 2}, time.Now().UTC().Add(-2*time.Minute))
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}

	if _, err := manager.Parse(raw); !errors.Is(err, jwtlib.ErrTokenExpired) {
		t.Fatalf("Parse() error = %v, want jwt.ErrTokenExpired", err)
	}
}

func TestManagerRejectsTokenSignedWithDifferentKey(t *testing.T) {
	issuer := "cbizdocsmanager"
	signer := mustManager(t, "first-secret", issuer, 15*time.Minute)
	parser := mustManager(t, "second-secret", issuer, 15*time.Minute)
	raw, _, err := signer.Sign(Claims{UserID: 1, SessionID: 2}, time.Now().UTC())
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}

	if _, err := parser.Parse(raw); err == nil {
		t.Fatal("Parse() must reject a token signed with a different key")
	}
}

func TestManagerRejectsTokenFromDifferentIssuer(t *testing.T) {
	secret := "shared-secret"
	signer := mustManager(t, secret, "other-service", 15*time.Minute)
	parser := mustManager(t, secret, "cbizdocsmanager", 15*time.Minute)
	raw, _, err := signer.Sign(Claims{UserID: 1, SessionID: 2}, time.Now().UTC())
	if err != nil {
		t.Fatalf("Sign() error = %v", err)
	}

	if _, err := parser.Parse(raw); !errors.Is(err, jwtlib.ErrTokenInvalidIssuer) {
		t.Fatalf("Parse() error = %v, want jwt.ErrTokenInvalidIssuer", err)
	}
}

func TestManagerRejectsOtherSigningAlgorithm(t *testing.T) {
	const (
		secret = "shared-secret"
		issuer = "cbizdocsmanager"
	)
	manager := mustManager(t, secret, issuer, 15*time.Minute)
	now := time.Now().UTC()
	claims := Claims{
		UserID:    1,
		SessionID: 2,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    issuer,
			IssuedAt:  jwtlib.NewNumericDate(now),
			NotBefore: jwtlib.NewNumericDate(now),
			ExpiresAt: jwtlib.NewNumericDate(now.Add(15 * time.Minute)),
		},
	}
	token := jwtlib.NewWithClaims(jwtlib.SigningMethodHS384, claims)
	raw, err := token.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("SignedString() error = %v", err)
	}

	if _, err := manager.Parse(raw); err == nil {
		t.Fatal("Parse() must reject algorithms other than HS256")
	}
}

func mustManager(t *testing.T, secret, issuer string, ttl time.Duration) *Manager {
	t.Helper()

	manager, err := NewManager(secret, issuer, ttl)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	return manager
}

func mustSignClaims(t *testing.T, secret string, claims Claims) string {
	t.Helper()

	token := jwtlib.NewWithClaims(jwtlib.SigningMethodHS256, claims)
	raw, err := token.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("SignedString() error = %v", err)
	}
	return raw
}
