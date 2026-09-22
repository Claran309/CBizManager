package cryptography

import (
	"bytes"
	"strings"
	"testing"
)

func TestInvitationCipherBindsCiphertextToGroupAndHash(t *testing.T) {
	key := bytes.Repeat([]byte{0x42}, 32)
	cipher, err := NewInvitationCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, nonce, err := cipher.Encrypt("secret-code", 7, strings.Repeat("a", 64))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := cipher.Decrypt(ciphertext, nonce, 7, strings.Repeat("a", 64)); err != nil || got != "secret-code" {
		t.Fatalf("Decrypt()=(%q,%v)", got, err)
	}
	if _, err := cipher.Decrypt(ciphertext, nonce, 8, strings.Repeat("a", 64)); err == nil {
		t.Fatal("Decrypt() with another group succeeded")
	}
	if _, err := cipher.Decrypt(ciphertext, nonce, 7, strings.Repeat("b", 64)); err == nil {
		t.Fatal("Decrypt() with another hash succeeded")
	}
	if _, err := cipher.Decrypt(ciphertext, []byte("bad"), 7, strings.Repeat("a", 64)); err == nil {
		t.Fatal("Decrypt() with invalid nonce succeeded")
	}
}
