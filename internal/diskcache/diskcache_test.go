package diskcache

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hacker65536/aws-sso-profile-generator/internal/ssoapi"
)

func sampleInv() []ssoapi.AccountRoles {
	return []ssoapi.AccountRoles{
		{Account: ssoapi.Account{ID: "1", Name: "acct one"}, Roles: []string{"RoleA", "RoleB"}},
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	c := &Cache{Dir: t.TempDir(), TTL: time.Hour}
	url := "https://x/start"
	if _, ok := c.Load(url); ok {
		t.Fatal("empty cache should miss")
	}
	if err := c.Save(url, sampleInv()); err != nil {
		t.Fatal(err)
	}
	got, ok := c.Load(url)
	if !ok || len(got) != 1 || got[0].Account.ID != "1" || len(got[0].Roles) != 2 {
		t.Fatalf("load mismatch: ok=%v got=%+v", ok, got)
	}
}

func TestExpiry(t *testing.T) {
	c := &Cache{Dir: t.TempDir(), TTL: time.Nanosecond}
	url := "https://x/start"
	if err := c.Save(url, sampleInv()); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	if _, ok := c.Load(url); ok {
		t.Error("expired entry should miss")
	}
}

func TestDifferentURLDifferentKey(t *testing.T) {
	c := &Cache{Dir: t.TempDir(), TTL: time.Hour}
	_ = c.Save("https://a/start", sampleInv())
	if _, ok := c.Load("https://b/start"); ok {
		t.Error("different start URL must not hit another URL's cache")
	}
}

func TestClear(t *testing.T) {
	dir := t.TempDir()
	c := &Cache{Dir: dir, TTL: time.Hour}
	_ = c.Save("https://x/start", sampleInv())
	if err := c.Clear(); err != nil {
		t.Fatal(err)
	}
	if _, ok := c.Load("https://x/start"); ok {
		t.Error("cache should be empty after Clear")
	}
	files, _ := filepath.Glob(filepath.Join(dir, "inventory-*.json"))
	if len(files) != 0 {
		t.Errorf("Clear left files: %v", files)
	}
}

func TestNewFromEnv(t *testing.T) {
	t.Setenv("CACHE_DIR", "/tmp/asp-cache-test")
	t.Setenv("CACHE_EXPIRY_HOURS", "1")
	c := New()
	if c.Dir != "/tmp/asp-cache-test" || c.TTL != time.Hour {
		t.Errorf("env not honored: dir=%s ttl=%s", c.Dir, c.TTL)
	}
	_ = os.Remove("/tmp/asp-cache-test")
}
