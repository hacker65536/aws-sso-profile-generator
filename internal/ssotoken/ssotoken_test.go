package ssotoken

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/credentials/ssocreds"
)

func writeCache(t *testing.T, path, startURL, token string, exp time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `{"startUrl":"` + startURL + `","region":"us-east-1","accessToken":"` + token +
		`","expiresAt":"` + exp.UTC().Format(time.RFC3339) + `"}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoadFromStandardPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	p, err := ssocreds.StandardCachedTokenFilepath("my-sso")
	if err != nil {
		t.Fatal(err)
	}
	exp := time.Now().Add(time.Hour)
	writeCache(t, p, "https://x/start", "TOKEN123", exp)

	tok, err := Load("my-sso", "https://x/start")
	if err != nil {
		t.Fatal(err)
	}
	if tok.AccessToken != "TOKEN123" {
		t.Errorf("token = %q", tok.AccessToken)
	}
	if tok.Expired() {
		t.Error("token should not be expired")
	}
}

func TestLoadFallbackByStartURL(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// A file NOT named by the session-name SHA1, matched only by startUrl.
	other := filepath.Join(home, ".aws", "sso", "cache", "random-name.json")
	writeCache(t, other, "https://y/start", "FALLBACK", time.Now().Add(time.Hour))

	tok, err := Load("unknown-session", "https://y/start")
	if err != nil {
		t.Fatal(err)
	}
	if tok.AccessToken != "FALLBACK" {
		t.Errorf("fallback token = %q", tok.AccessToken)
	}
}

func TestExpiredToken(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	p, _ := ssocreds.StandardCachedTokenFilepath("s")
	writeCache(t, p, "https://z/start", "OLD", time.Now().Add(-time.Minute))

	tok, err := Load("s", "https://z/start")
	if err != nil {
		t.Fatal(err)
	}
	if !tok.Expired() {
		t.Error("token should be expired")
	}
}

func TestLoadMissing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := Load("nope", "https://none/start"); err == nil {
		t.Error("expected error when no cache present")
	}
}
