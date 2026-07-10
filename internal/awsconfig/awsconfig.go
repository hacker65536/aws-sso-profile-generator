// Package awsconfig reads and mutates ~/.aws/config without disturbing any
// content it does not own.
//
// The tool's managed profiles live inside prefix-scoped marker blocks:
//
//	# AWS_SSO_CONFIG_GENERATOR:<prefix> START <datetime>
//	<body>
//	# AWS_SSO_CONFIG_GENERATOR:<prefix> END <datetime>
//
// The volatile <datetime> lives only on the marker lines (owned here); the
// <body> is produced deterministically by the render package, so byte-equality
// of the body is a sound no-op test (see SpliceBlock / ExtractBlockBody).
//
// All parsing and splicing is done by a hand-written line scanner rather than
// an INI library, so every byte outside the managed block — comments, spacing,
// ordering, other prefixes' blocks — is preserved verbatim.
package awsconfig

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const markerPrefix = "# AWS_SSO_CONFIG_GENERATOR:"

var markerRe = regexp.MustCompile(`^# AWS_SSO_CONFIG_GENERATOR:(\S+) (START|END)\b`)

// Path resolves the AWS config file: $AWS_CONFIG_FILE, else ~/.aws/config.
func Path() string {
	if p := os.Getenv("AWS_CONFIG_FILE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".aws", "config")
	}
	return filepath.Join(home, ".aws", "config")
}

// NowStamp returns the marker datetime in the bash tool's format.
func NowStamp() string { return time.Now().Format("2006/01/02 15:04:05") }

// ---- line helpers (newline-preserving) ----

func splitLines(s string) (lines []string, finalNewline bool) {
	if s == "" {
		return nil, false
	}
	finalNewline = strings.HasSuffix(s, "\n")
	body := strings.TrimSuffix(s, "\n")
	return strings.Split(body, "\n"), finalNewline
}

func joinLines(lines []string, finalNewline bool) string {
	s := strings.Join(lines, "\n")
	if finalNewline && s != "" {
		s += "\n"
	}
	return s
}

func parseMarker(line string) (prefix, kind string, ok bool) {
	m := markerRe.FindStringSubmatch(line)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// findBlockRange returns the inclusive [start,end] line indices of the marker
// block for prefix. It enforces balanced markers and at most one block.
func findBlockRange(lines []string, prefix string) (start, end int, found bool, err error) {
	start, end = -1, -1
	for i, ln := range lines {
		p, kind, ok := parseMarker(ln)
		if !ok || p != prefix {
			continue
		}
		switch kind {
		case "START":
			if start != -1 {
				return 0, 0, false, fmt.Errorf("multiple START markers for prefix %q", prefix)
			}
			start = i
		case "END":
			if start == -1 {
				return 0, 0, false, fmt.Errorf("END marker before START for prefix %q", prefix)
			}
			if end != -1 {
				return 0, 0, false, fmt.Errorf("multiple END markers for prefix %q", prefix)
			}
			end = i
		}
	}
	if start == -1 && end == -1 {
		return -1, -1, false, nil
	}
	if start == -1 || end == -1 || end < start {
		return 0, 0, false, fmt.Errorf("unbalanced markers for prefix %q (START/END must pair)", prefix)
	}
	return start, end, true, nil
}

// ExtractBlockBody returns the exact text between the START and END markers for
// prefix (no marker lines). found=false when no block exists.
func ExtractBlockBody(content, prefix string) (body string, found bool, err error) {
	lines, _ := splitLines(content)
	s, e, found, err := findBlockRange(lines, prefix)
	if err != nil || !found {
		return "", found, err
	}
	return strings.Join(lines[s+1:e], "\n"), true, nil
}

// RemoveBlock removes prefix's marker block (and one preceding blank line, to
// avoid blank-line accumulation across runs). No-op if absent.
func RemoveBlock(content, prefix string) (string, error) {
	lines, fnl := splitLines(content)
	s, e, found, err := findBlockRange(lines, prefix)
	if err != nil {
		return "", err
	}
	if !found {
		return content, nil
	}
	start := s
	if start > 0 && strings.TrimSpace(lines[start-1]) == "" {
		start--
	}
	kept := append(append([]string{}, lines[:start]...), lines[e+1:]...)
	return joinLines(kept, fnl), nil
}

// SpliceBlock replaces (or appends) prefix's block with markers wrapping body.
// The block is emitted at EOF after removing any prior block for this prefix.
// body must not contain a trailing newline.
func SpliceBlock(content, prefix, body, datetime string) (string, error) {
	removed, err := RemoveBlock(content, prefix)
	if err != nil {
		return "", err
	}
	block := strings.Join([]string{
		fmt.Sprintf("%s%s START %s", markerPrefix, prefix, datetime),
		body,
		fmt.Sprintf("%s%s END %s", markerPrefix, prefix, datetime),
	}, "\n")

	base := strings.TrimRight(removed, "\n")
	if base == "" {
		return block + "\n", nil
	}
	return base + "\n\n" + block + "\n", nil
}

// ---- [sso-session] parsing ----

// SSOSession holds the two fields the tool consumes from an [sso-session] block.
type SSOSession struct {
	Name     string
	Region   string // sso_region — the SSO API region (authoritative)
	StartURL string // sso_start_url
}

var (
	ssoSessionHdr = regexp.MustCompile(`^\[sso-session[ \t]+([^\]]+)\]`)
	sectionHdr    = regexp.MustCompile(`^\[`)
	kvRe          = regexp.MustCompile(`^([A-Za-z0-9_]+)[ \t]*=[ \t]*(.*)$`)
)

// ParseSSOSessions returns every [sso-session NAME] block in file order.
func ParseSSOSessions(content string) []SSOSession {
	lines, _ := splitLines(content)
	var out []SSOSession
	cur := -1
	for _, ln := range lines {
		if m := ssoSessionHdr.FindStringSubmatch(ln); m != nil {
			out = append(out, SSOSession{Name: strings.TrimSpace(m[1])})
			cur = len(out) - 1
			continue
		}
		if sectionHdr.MatchString(ln) { // any other section ends the current block
			cur = -1
			continue
		}
		if cur == -1 {
			continue
		}
		if kv := kvRe.FindStringSubmatch(ln); kv != nil {
			switch kv[1] {
			case "sso_region":
				out[cur].Region = strings.TrimSpace(kv[2])
			case "sso_start_url":
				out[cur].StartURL = strings.TrimSpace(kv[2])
			}
		}
	}
	return out
}

// SelectSSOSession picks the named session, or the first in file order when
// name is empty (invariant 7).
func SelectSSOSession(sessions []SSOSession, name string) (SSOSession, error) {
	if len(sessions) == 0 {
		return SSOSession{}, fmt.Errorf("no [sso-session] block found in AWS config")
	}
	if name == "" {
		return sessions[0], nil
	}
	for _, s := range sessions {
		if s.Name == name {
			return s, nil
		}
	}
	return SSOSession{}, fmt.Errorf("sso-session %q not found in AWS config", name)
}

// AmbientRegion resolves the general CLI region used only as a fallback for the
// profile region: AWS_REGION > AWS_DEFAULT_REGION > [default].region.
func AmbientRegion(content string) string {
	if r := os.Getenv("AWS_REGION"); r != "" {
		return r
	}
	if r := os.Getenv("AWS_DEFAULT_REGION"); r != "" {
		return r
	}
	return profileRegion(content, "default")
}

func profileRegion(content, profile string) string {
	lines, _ := splitLines(content)
	header := "[" + profile + "]"
	if profile != "default" {
		header = "[profile " + profile + "]"
	}
	in := false
	for _, ln := range lines {
		if strings.HasPrefix(ln, "[") {
			in = strings.TrimSpace(ln) == header
			continue
		}
		if !in {
			continue
		}
		if kv := kvRe.FindStringSubmatch(ln); kv != nil && kv[1] == "region" {
			return strings.TrimSpace(kv[2])
		}
	}
	return ""
}

// EnsureSSOSession appends an [sso-session name] block from the seed if absent.
// Returns the (possibly unchanged) content and whether a block was added.
func EnsureSSOSession(content string, s SSOSession, scopes string) (string, bool) {
	for _, ex := range ParseSSOSessions(content) {
		if ex.Name == s.Name {
			return content, false
		}
	}
	block := strings.Join([]string{
		fmt.Sprintf("[sso-session %s]", s.Name),
		fmt.Sprintf("sso_start_url = %s", s.StartURL),
		fmt.Sprintf("sso_region = %s", s.Region),
		fmt.Sprintf("sso_registration_scopes = %s", scopes),
	}, "\n")
	base := strings.TrimRight(content, "\n")
	if base == "" {
		return block + "\n", true
	}
	return base + "\n\n" + block + "\n", true
}

// ---- profile parsing (managed block bodies) ----

// Profile is one [profile NAME] stanza with its key/values.
type Profile struct {
	Name string
	Keys map[string]string
}

var profileHdr = regexp.MustCompile(`^\[profile[ \t]+([^\]]+)\]`)

// ParseProfiles extracts [profile ...] stanzas from an INI fragment (e.g. a
// managed block body). Comment lines are ignored.
func ParseProfiles(fragment string) []Profile {
	lines, _ := splitLines(fragment)
	var out []Profile
	cur := -1
	for _, ln := range lines {
		if m := profileHdr.FindStringSubmatch(ln); m != nil {
			out = append(out, Profile{Name: strings.TrimSpace(m[1]), Keys: map[string]string{}})
			cur = len(out) - 1
			continue
		}
		if strings.HasPrefix(ln, "[") {
			cur = -1
			continue
		}
		if cur == -1 || strings.HasPrefix(strings.TrimSpace(ln), "#") {
			continue
		}
		if kv := kvRe.FindStringSubmatch(ln); kv != nil {
			out[cur].Keys[kv[1]] = strings.TrimSpace(kv[2])
		}
	}
	return out
}

// AllProfileNames returns every [profile NAME] in the file, in order.
func AllProfileNames(content string) []string {
	lines, _ := splitLines(content)
	var out []string
	for _, ln := range lines {
		if m := profileHdr.FindStringSubmatch(ln); m != nil {
			out = append(out, strings.TrimSpace(m[1]))
		}
	}
	return out
}

// ManagedProfileNames returns the set of profiles inside ANY generator marker
// block (regardless of prefix). Everything else is hand-managed.
func ManagedProfileNames(content string) map[string]bool {
	lines, _ := splitLines(content)
	managed := map[string]bool{}
	in := false
	for _, ln := range lines {
		if _, kind, ok := parseMarker(ln); ok {
			switch kind {
			case "START":
				in = true
			case "END":
				in = false
			}
			continue
		}
		if in {
			if m := profileHdr.FindStringSubmatch(ln); m != nil {
				managed[strings.TrimSpace(m[1])] = true
			}
		}
	}
	return managed
}

// ---- IO: backup + atomic write ----

// Backup copies path to path.backup.<timestamp> and prunes to the newest keep.
// If path does not exist, it is a no-op returning an empty backup path.
func Backup(path string, keep int) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	info, _ := os.Stat(path)
	mode := os.FileMode(0o600)
	if info != nil {
		mode = info.Mode()
	}
	bak := path + ".backup." + time.Now().Format("20060102_150405")
	if err := os.WriteFile(bak, data, mode); err != nil {
		return "", err
	}
	rotateBackups(path, keep)
	return bak, nil
}

func rotateBackups(path string, keep int) {
	matches, err := filepath.Glob(path + ".backup.*")
	if err != nil || len(matches) <= keep {
		return
	}
	sort.Strings(matches) // timestamp suffix sorts chronologically
	for _, old := range matches[:len(matches)-keep] {
		_ = os.Remove(old)
	}
}

// WriteAtomic writes content to path via a temp file + rename, preserving mode.
func WriteAtomic(path, content string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode()
	}
	tmp, err := os.CreateTemp(dir, ".aws-sso-profiles-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
