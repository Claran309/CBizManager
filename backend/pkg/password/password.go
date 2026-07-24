package password

import (
	"errors"

	"golang.org/x/crypto/bcrypt"
)

var ErrEmptyPassword = errors.New("密码不能为空")

// Hash 使用 bcrypt 对明文密码进行单向哈希。
func Hash(plain string) (string, error) {
	if plain == "" {
		return "", ErrEmptyPassword
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

// Verify 检查明文密码是否与 bcrypt 哈希匹配。
func Verify(hash, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}
