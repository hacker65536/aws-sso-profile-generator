// Package ssotoken reads the SSO bearer token that `aws sso login` cached under
// ~/.aws/sso/cache. It never performs OIDC/login itself — it only consumes an
// existing token, matching the original tool's read-only contract.
package ssotoken

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/credentials/ssocreds"
)

// Token is the subset of the cached SSO token file the tool consumes.
type Token struct {
	AccessToken string
	ExpiresAt   time.Time
	StartURL    string
	Region      string
}

// cacheFile mirrors the on-disk JSON written by `aws sso login`.
type cacheFile struct {
	StartURL    string `json:"startUrl"`
	Region      string `json:"region"`
	AccessToken string `json:"accessToken"`
	ExpiresAt   string `json:"expiresAt"`
}

// Expired reports whether the token is at or past its expiry.
func (t Token) Expired() bool { return !t.ExpiresAt.IsZero() && !time.Now().Before(t.ExpiresAt) }

// LoginHint is the command the user should run to (re)authenticate.
func LoginHint(sessionName string) string {
	return fmt.Sprintf("aws sso login --sso-session %s", sessionName)
}

// Load resolves the cached token for the session. It first tries the SDK's
// canonical path (SHA1 of the session name); if that is absent it falls back to
// scanning ~/.aws/sso/cache for the newest file whose startUrl matches, which
// preserves parity with legacy logins keyed differently.
func Load(sessionName, startURL string) (Token, error) {
	if sessionName != "" {
		if p, err := ssocreds.StandardCachedTokenFilepath(sessionName); err == nil {
			if tok, err := readTokenFile(p); err == nil {
				return tok, nil
			}
		}
	}
	if startURL != "" {
		if tok, err := findByStartURL(startURL); err == nil {
			return tok, nil
		}
	}
	return Token{}, fmt.Errorf("no cached SSO token found; run: %s", LoginHint(sessionName))
}

func readTokenFile(path string) (Token, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Token{}, err
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		return Token{}, fmt.Errorf("parse token file %s: %w", path, err)
	}
	if cf.AccessToken == "" {
		return Token{}, fmt.Errorf("token file %s has no accessToken", path)
	}
	tok := Token{AccessToken: cf.AccessToken, StartURL: cf.StartURL, Region: cf.Region}
	if cf.ExpiresAt != "" {
		tok.ExpiresAt = parseExpiry(cf.ExpiresAt)
	}
	return tok, nil
}

func parseExpiry(s string) time.Time {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05Z0700", "2006-01-02T15:04:05UTC"} {
		if ts, err := time.Parse(layout, s); err == nil {
			return ts.UTC()
		}
	}
	return time.Time{}
}

func cacheDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".aws", "sso", "cache"), nil
}

// findByStartURL scans the cache dir for JSON files whose startUrl matches,
// returning the newest by mtime (parity with the bash `grep -l | ls -t` path).
func findByStartURL(startURL string) (Token, error) {
	dir, err := cacheDir()
	if err != nil {
		return Token{}, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Token{}, err
	}
	type cand struct {
		tok   Token
		mtime time.Time
	}
	var cands []cand
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		tok, err := readTokenFile(p)
		if err != nil || tok.StartURL != startURL {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		cands = append(cands, cand{tok, info.ModTime()})
	}
	if len(cands) == 0 {
		return Token{}, fmt.Errorf("no cache file matched startUrl %q", startURL)
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].mtime.After(cands[j].mtime) })
	return cands[0].tok, nil
}
