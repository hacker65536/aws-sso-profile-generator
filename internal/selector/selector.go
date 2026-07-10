// Package selector decides which (account, role) pairs become profiles and
// resolves per-match region overrides. Matching uses simple `*`/`?` globs over
// account and role names (no character classes), so patterns always compile.
package selector

import (
	"regexp"
	"strings"
)

// Rule is a glob pair. An empty string is treated as "*".
type Rule struct {
	Account string `json:"account"`
	Role    string `json:"role"`
}

type compiledRule struct {
	acct *regexp.Regexp
	role *regexp.Regexp
}

func compile(r Rule) compiledRule {
	return compiledRule{acct: globToRegexp(r.Account), role: globToRegexp(r.Role)}
}

func (c compiledRule) match(account, role string) bool {
	return c.acct.MatchString(account) && c.role.MatchString(role)
}

// Selector applies include/exclude rules. Empty include ⇒ include everything;
// any matching exclude wins.
type Selector struct {
	include []compiledRule
	exclude []compiledRule
}

// New compiles a selector from include/exclude rule lists.
func New(include, exclude []Rule) *Selector {
	s := &Selector{}
	for _, r := range include {
		s.include = append(s.include, compile(r))
	}
	for _, r := range exclude {
		s.exclude = append(s.exclude, compile(r))
	}
	return s
}

// Selected reports whether (account, role) should become a profile.
func (s *Selector) Selected(account, role string) bool {
	included := len(s.include) == 0
	for _, r := range s.include {
		if r.match(account, role) {
			included = true
			break
		}
	}
	if !included {
		return false
	}
	for _, r := range s.exclude {
		if r.match(account, role) {
			return false
		}
	}
	return true
}

// Override supplies profile settings to matching profiles.
type Override struct {
	Match    Rule              `json:"match"`
	Settings map[string]string `json:"settings,omitempty"`
}

type compiledOverride struct {
	rule     compiledRule
	settings map[string]string
}

// Overrides resolves the first matching override's settings.
type Overrides struct {
	rules []compiledOverride
}

// NewOverrides compiles an override list (order preserved; first match wins).
func NewOverrides(list []Override) *Overrides {
	o := &Overrides{}
	for _, ov := range list {
		o.rules = append(o.rules, compiledOverride{rule: compile(ov.Match), settings: ov.Settings})
	}
	return o
}

// Settings returns the first matching override's settings map (nil if none).
func (o *Overrides) Settings(account, role string) map[string]string {
	if o == nil {
		return nil
	}
	for _, r := range o.rules {
		if r.rule.match(account, role) {
			return r.settings
		}
	}
	return nil
}

func globToRegexp(pat string) *regexp.Regexp {
	if pat == "" {
		pat = "*"
	}
	var b strings.Builder
	b.WriteByte('^')
	for _, r := range pat {
		switch r {
		case '*':
			b.WriteString(".*")
		case '?':
			b.WriteString(".")
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteByte('$')
	return regexp.MustCompile(b.String())
}
