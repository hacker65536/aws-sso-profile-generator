// Package render produces the managed-block body: a deterministic, byte-stable
// serialization of the desired profiles. The body deliberately contains no
// volatile data (timestamps live only on the START/END marker lines owned by
// awsconfig), so byte-equality of two bodies is a sound no-op test for apply.
package render

import (
	"fmt"
	"sort"
	"strings"

	"github.com/hacker65536/aws-sso-profile-generator/internal/plan"
)

// Provenance is the audit metadata stamped into the managed block's first line.
// Both fields are stable given a build + config, so they do not perturb the
// no-op decision (which is plan-based, not byte-based).
type Provenance struct {
	Version   string
	ConfigSHA string
}

// Header renders the provenance comment written as the first body line.
func Header(p Provenance) string {
	v := p.Version
	if v == "" {
		v = "(dev)"
	}
	sha := p.ConfigSHA
	if sha == "" {
		sha = "-"
	}
	return fmt.Sprintf("# managed by aws-sso-profiles %s — do not edit; config-sha256=%s", v, sha)
}

// Body renders profiles into the managed-block body (provenance header + stanzas;
// no marker lines, no trailing newline). Profiles are sorted by name for
// determinism; each stanza reproduces the bash tool's exact key order (invariant 2).
func Body(profiles []plan.Profile, prov Provenance) string {
	sorted := append([]plan.Profile(nil), profiles...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Name < sorted[j].Name })

	var b strings.Builder
	b.WriteString(Header(prov))
	for _, p := range sorted {
		b.WriteString("\n\n")
		// Identity keys first, fixed order (invariant 2).
		fmt.Fprintf(&b, "[profile %s]\nsso_session = %s\nsso_account_id = %s\nsso_role_name = %s",
			p.Name, p.SSOSession, p.AccountID, p.RoleName)
		// Then settings, sorted by key for determinism.
		keys := make([]string, 0, len(p.Settings))
		for k := range p.Settings {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if v := p.Settings[k]; v == "" {
				fmt.Fprintf(&b, "\n%s =", k) // empty value: no trailing space (matches bash `cli_pager =`)
			} else {
				fmt.Fprintf(&b, "\n%s = %s", k, v)
			}
		}
	}
	return b.String()
}
