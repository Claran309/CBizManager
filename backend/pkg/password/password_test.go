package password

import "testing"

func TestHashAndVerifyPassword(t *testing.T) {
	plain := "correct horse battery staple"

	hash, err := Hash(plain)
	if err != nil {
		t.Fatalf("Hash() error = %v", err)
	}
	if hash == plain {
		t.Fatal("password hash must not equal plaintext")
	}
	if !Verify(hash, plain) {
		t.Fatal("Verify() must accept the correct password")
	}
	if Verify(hash, "wrong password") {
		t.Fatal("Verify() must reject an incorrect password")
	}
}

func TestHashRejectsEmptyPassword(t *testing.T) {
	if _, err := Hash(""); err == nil {
		t.Fatal("Hash() must reject an empty password")
	}
}

func TestVerifyRejectsMalformedHash(t *testing.T) {
	if Verify("not-a-bcrypt-hash", "password") {
		t.Fatal("Verify() must reject a malformed password hash")
	}
}
