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

	"github.com/hacker65536/aws-sso-profiles/internal/ssoapi"
)

// Cache is a directory-backed inventory cache.
type Cache struct {
	Dir string
	TTL time.Duration
}

// New builds a Cache from CACHE_DIR and CACHE_EXPIRY_HOURS (default 24).
//
// When CACHE_DIR is unset the cache lives under the user cache directory
// (~/.cache/aws-sso-profiles on Linux, ~/Library/Caches/... on macOS) rather
// than a CWD-relative ./.aws-sso-cache. The snapshot contains real account IDs
// and names, so anchoring it to a fixed per-user location avoids scattering
// copies across working directories where they could be accidentally committed.
func New() *Cache {
	dir := os.Getenv("CACHE_DIR")
	if dir == "" {
		if ucd, err := os.UserCacheDir(); err == nil {
			dir = filepath.Join(ucd, "aws-sso-profiles")
		} else {
			dir = ".aws-sso-cache" // last-resort fallback if the user cache dir is undiscoverable
		}
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
	// md5 is used purely as a non-cryptographic cache-key digest (byte-for-byte
	// parity with the original bash tool's key); it is not a security control.
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
	// Write via a randomized temp name (not a fixed p+".tmp") so a co-user in
	// the cache dir cannot pre-create/symlink the temp path to redirect the
	// write. os.CreateTemp makes the file 0600; the rename is atomic.
	tmp, err := os.CreateTemp(c.Dir, "inventory-*.json.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, p)
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
