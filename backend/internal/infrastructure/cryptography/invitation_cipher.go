package cryptography

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"strconv"
)

var ErrInvalidInvitationKey = errors.New("invitation encryption key must be 32 bytes")

type InvitationCipher interface {
	Encrypt(plain string, groupID uint64, codeHash string) (ciphertext, nonce []byte, err error)
	Decrypt(ciphertext, nonce []byte, groupID uint64, codeHash string) (string, error)
}

type invitationCipher struct{ gcm cipher.AEAD }

func NewInvitationCipher(key []byte) (InvitationCipher, error) {
	if len(key) != 32 {
		return nil, ErrInvalidInvitationKey
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create AES cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create GCM cipher: %w", err)
	}
	return &invitationCipher{gcm: gcm}, nil
}

func (c *invitationCipher) Encrypt(plain string, groupID uint64, codeHash string) ([]byte, []byte, error) {
	nonce := make([]byte, c.gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, fmt.Errorf("generate invitation nonce: %w", err)
	}
	ciphertext := c.gcm.Seal(nil, nonce, []byte(plain), invitationAAD(groupID, codeHash))
	return ciphertext, nonce, nil
}

func (c *invitationCipher) Decrypt(ciphertext, nonce []byte, groupID uint64, codeHash string) (string, error) {
	if len(nonce) != c.gcm.NonceSize() {
		return "", errors.New("invalid invitation nonce")
	}
	plain, err := c.gcm.Open(nil, nonce, ciphertext, invitationAAD(groupID, codeHash))
	if err != nil {
		return "", errors.New("invitation ciphertext authentication failed")
	}
	return string(plain), nil
}

func invitationAAD(groupID uint64, codeHash string) []byte {
	return []byte(strconv.FormatUint(groupID, 10) + ":" + codeHash)
}
