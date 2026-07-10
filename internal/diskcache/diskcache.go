// Package diskcache is an opt-in, on-disk cache of the SSO inventory. It is OFF
// by default (adaptive retry keeps live fetches fast and reliable); enable it
// with --cache for offline or rapid repeated runs.
//
// A single snapshot is stored per SSO instance, keyed by the first 8 hex of
// md5(start_url) — parity with the bash cache key, so changing the start URL
// auto-invalidates. Freshness is mtime-based against CACHE_EXPIRY_HOURS.
package diskcache

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/hacker65536/aws-sso-profile-generator/internal/ssoapi"
)

// Cache is a directory-backed inventory cache.
type Cache struct {
	Dir string
	TTL time.Duration
}

// New builds a Cache from CACHE_DIR (default ./.aws-sso-cache) and
// CACHE_EXPIRY_HOURS (default 24).
func New() *Cache {
	dir := os.Getenv("CACHE_DIR")
	if dir == "" {
		dir = ".aws-sso-cache"
	}
	hours := 24.0
	if v := os.Getenv("CACHE_EXPIRY_HOURS"); v != "" {
		if h, err := strconv.ParseFloat(v, 64); err == nil && h > 0 {
			hours = h
		}
	}
	return &Cache{Dir: dir, TTL: time.Duration(hours * float64(time.Hour))}
}

func key(startURL string) string {
	sum := md5.Sum([]byte(startURL))
	return hex.EncodeToString(sum[:])[:8]
}

func (c *Cache) path(startURL string) string {
	return filepath.Join(c.Dir, "inventory-"+key(startURL)+".json")
}

// Load returns the cached inventory if present and within TTL.
func (c *Cache) Load(startURL string) ([]ssoapi.AccountRoles, bool) {
	p := c.path(startURL)
	info, err := os.Stat(p)
	if err != nil {
		return nil, false
	}
	if time.Since(info.ModTime()) > c.TTL {
		return nil, false
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, false
	}
	var inv []ssoapi.AccountRoles
	if err := json.Unmarshal(data, &inv); err != nil {
		return nil, false
	}
	return inv, true
}

// Save writes the inventory snapshot atomically.
func (c *Cache) Save(startURL string, inv []ssoapi.AccountRoles) error {
	if err := os.MkdirAll(c.Dir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(inv, "", "  ")
	if err != nil {
		return err
	}
	p := c.path(startURL)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// Clear removes all cached inventory snapshots.
func (c *Cache) Clear() error {
	matches, err := filepath.Glob(filepath.Join(c.Dir, "inventory-*.json"))
	if err != nil {
		return err
	}
	for _, m := range matches {
		if err := os.Remove(m); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}
