// Package naming reproduces the bash tool's account-name normalization and
// profile-name template expansion.
//
// Normalization is intentionally ASCII-only to stay byte-for-byte compatible
// with the original bash implementation (pure parameter-expansion over an
// effectively-ASCII locale). Go's Unicode-aware strings.ToLower would diverge
// on non-ASCII input, so we lowercase and classify over raw bytes here.
package naming

import (
	"fmt"
	"regexp"
	"strings"
)

// Mode selects the normalization strategy.
type Mode string

const (
	// Minimal maps ASCII whitespace to '_' only, preserves case and hyphens,
	// and drops anything outside [A-Za-z0-9_-]. This is the default.
	Minimal Mode = "minimal"
	// Full lowercases ASCII, maps ASCII whitespace and '-' to '_', and drops
	// anything outside [a-z0-9_].
	Full Mode = "full"
)

// Normalize applies the given normalization mode. Unknown modes fall back to
// Minimal, matching the bash dispatcher's default branch.
func Normalize(name string, mode Mode) string {
	if mode == Full {
		return normalizeFull(name)
	}
	return normalizeMinimal(name)
}

// normalizeMinimal: space -> '_'; keep [A-Za-z0-9_-]; drop the rest.
func normalizeMinimal(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ { // byte iteration: non-ASCII bytes (>=0x80) are dropped
		c := s[i]
		switch {
		case isASCIISpace(c):
			b.WriteByte('_')
		case isAlnum(c) || c == '_' || c == '-':
			b.WriteByte(c)
		}
	}
	return b.String()
}

// normalizeFull: lowercase ASCII; (space|'-') -> '_'; keep [a-z0-9_]; drop the rest.
func normalizeFull(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		switch {
		case isASCIISpace(c) || c == '-':
			b.WriteByte('_')
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_':
			b.WriteByte(c)
		}
	}
	return b.String()
}

func isASCIISpace(c byte) bool {
	// POSIX [[:space:]] over ASCII: space, \t, \n, \v, \f, \r.
	switch c {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	}
	return false
}

func isAlnum(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// Known template variables. {account_name} is the normalized name; {role} is raw.
var knownVars = map[string]struct{}{
	"prefix":       {},
	"account_name": {},
	"account_id":   {},
	"role":         {},
}

// DefaultTemplate matches the bash profile-name shape.
const DefaultTemplate = "{prefix}-{account_name}-{account_id}:{role}"

var tmplToken = regexp.MustCompile(`\{([^{}]*)\}`)

// ValidateTemplate rejects a template referencing any unknown {token}.
func ValidateTemplate(tmpl string) error {
	var unknown []string
	seen := map[string]struct{}{}
	for _, m := range tmplToken.FindAllStringSubmatch(tmpl, -1) {
		k := m[1]
		if _, ok := knownVars[k]; !ok {
			if _, dup := seen[k]; !dup {
				seen[k] = struct{}{}
				unknown = append(unknown, k)
			}
		}
	}
	if len(unknown) > 0 {
		return fmt.Errorf("unknown template variable(s): %s (known: prefix, account_name, account_id, role)", strings.Join(unknown, ", "))
	}
	return nil
}

// Expand substitutes {token}s from vars. Any unknown token is an error.
func Expand(tmpl string, vars map[string]string) (string, error) {
	var unknown []string
	out := tmplToken.ReplaceAllStringFunc(tmpl, func(m string) string {
		k := m[1 : len(m)-1]
		if v, ok := vars[k]; ok {
			return v
		}
		unknown = append(unknown, k)
		return m
	})
	if len(unknown) > 0 {
		return "", fmt.Errorf("unknown template variable(s): %s", strings.Join(unknown, ", "))
	}
	return out, nil
}

// ProfileName builds a profile name: normalize the account name, then expand
// the template. role is used raw (not normalized), per the invariant.
func ProfileName(tmpl, prefix, accountName, accountID, role string, mode Mode) (string, error) {
	return Expand(tmpl, map[string]string{
		"prefix":       prefix,
		"account_name": Normalize(accountName, mode),
		"account_id":   accountID,
		"role":         role,
	})
}
