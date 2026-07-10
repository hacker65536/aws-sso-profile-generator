// Package plan is the desired-state engine: it derives the desired set of
// profiles from the SSO inventory + config policy, and diffs it against the
// profiles currently in the managed block (added / removed / changed /
// unchanged). apply reuses the same engine so its output and exit codes match
// plan exactly.
package plan

import (
	"fmt"
	"sort"
	"strings"

	"github.com/hacker65536/aws-sso-profile-generator/internal/awsconfig"
	"github.com/hacker65536/aws-sso-profile-generator/internal/naming"
	"github.com/hacker65536/aws-sso-profile-generator/internal/selector"
	"github.com/hacker65536/aws-sso-profile-generator/internal/ssoapi"
)

// IdentityKeys are tool-owned and must never appear in user settings.
var IdentityKeys = map[string]bool{
	"sso_session": true, "sso_account_id": true, "sso_role_name": true,
}

// Params carries the config policy needed to build desired profiles.
type Params struct {
	Prefix          string
	SSOSession      string
	Template        string
	Normalize       naming.Mode
	DefaultSettings map[string]string // resolved base settings (region/output/cli_pager + user defaults)
	Selector        *selector.Selector
	Overrides       *selector.Overrides
}

// Profile is a desired profile: identity fields plus the settings key/values
// injected into the [profile] stanza.
type Profile struct {
	Name       string            `json:"name"`
	SSOSession string            `json:"sso_session"`
	AccountID  string            `json:"sso_account_id"`
	RoleName   string            `json:"sso_role_name"`
	Settings   map[string]string `json:"settings"`
}

// BuildDesired expands the inventory through the selector, overrides and naming
// template. It errors if two profiles render to the same name (proposal 3:
// collision detection prevents silent profile loss).
func BuildDesired(inv []ssoapi.AccountRoles, p Params) ([]Profile, error) {
	if err := naming.ValidateTemplate(p.Template); err != nil {
		return nil, err
	}
	var desired []Profile
	seen := map[string]Profile{}
	var collisions []string
	for _, ar := range inv {
		for _, role := range ar.Roles {
			if !p.Selector.Selected(ar.Account.Name, role) {
				continue
			}
			name, err := naming.ProfileName(p.Template, p.Prefix, ar.Account.Name, ar.Account.ID, role, p.Normalize)
			if err != nil {
				return nil, err
			}
			settings := mergeSettings(p.DefaultSettings, p.Overrides.Settings(ar.Account.Name, role))
			prof := Profile{Name: name, SSOSession: p.SSOSession, AccountID: ar.Account.ID, RoleName: role, Settings: settings}
			if prev, dup := seen[name]; dup {
				collisions = append(collisions, fmt.Sprintf("%q (from %s:%s and %s:%s)",
					name, prev.AccountID, prev.RoleName, prof.AccountID, prof.RoleName))
				continue
			}
			seen[name] = prof
			desired = append(desired, prof)
		}
	}
	if len(collisions) > 0 {
		return nil, fmt.Errorf("profile name collisions (add {account_id} to the template to disambiguate):\n  %s",
			strings.Join(collisions, "\n  "))
	}
	sort.Slice(desired, func(i, j int) bool { return desired[i].Name < desired[j].Name })
	return desired, nil
}

// ChangeKind classifies a single profile's change.
type ChangeKind string

const (
	Added     ChangeKind = "added"
	Removed   ChangeKind = "removed"
	Changed   ChangeKind = "changed"
	Unchanged ChangeKind = "unchanged"
)

// Change is one profile's diff entry.
type Change struct {
	Kind    ChangeKind `json:"kind"`
	Name    string     `json:"name"`
	Detail  string     `json:"detail,omitempty"`
	Desired *Profile   `json:"desired,omitempty"`
}

// DriftItem flags a hand-edit inside the managed block that the tool would not
// have produced (proposal 6). Field changes are already surfaced as CHANGED
// because desired is regenerated from the inventory; this additionally catches
// unexpected keys added by hand.
type DriftItem struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

// mergeSettings returns base overlaid with over (over wins). Never mutates inputs.
func mergeSettings(base, over map[string]string) map[string]string {
	out := make(map[string]string, len(base)+len(over))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range over {
		out[k] = v
	}
	return out
}

// Plan is the full diff.
type Plan struct {
	Changes []Change    `json:"changes"`
	Drift   []DriftItem `json:"drift,omitempty"`
}

// Diff compares desired against the current managed-block profiles (by name).
func Diff(desired []Profile, current []awsconfig.Profile) *Plan {
	curByName := make(map[string]awsconfig.Profile, len(current))
	for _, c := range current {
		curByName[c.Name] = c
	}
	desiredNames := make(map[string]struct{}, len(desired))
	pl := &Plan{}
	pl.Drift = detectDrift(current, allowedKeys(desired))
	for _, d := range desired {
		d := d
		desiredNames[d.Name] = struct{}{}
		cur, ok := curByName[d.Name]
		if !ok {
			pl.Changes = append(pl.Changes, Change{Kind: Added, Name: d.Name, Desired: &d})
			continue
		}
		if detail := changedFields(d, cur); detail != "" {
			pl.Changes = append(pl.Changes, Change{Kind: Changed, Name: d.Name, Desired: &d, Detail: detail})
		} else {
			pl.Changes = append(pl.Changes, Change{Kind: Unchanged, Name: d.Name, Desired: &d})
		}
	}
	for _, c := range current {
		if _, ok := desiredNames[c.Name]; !ok {
			c := c
			pl.Changes = append(pl.Changes, Change{Kind: Removed, Name: c.Name})
		}
	}
	sort.SliceStable(pl.Changes, func(i, j int) bool {
		if pl.Changes[i].Name != pl.Changes[j].Name {
			return pl.Changes[i].Name < pl.Changes[j].Name
		}
		return pl.Changes[i].Kind < pl.Changes[j].Kind
	})
	return pl
}

// changedFields returns a human-readable summary if the current profile's
// meaningful fields differ from desired, else "". It compares identity fields
// and every desired setting key.
func changedFields(d Profile, c awsconfig.Profile) string {
	var diffs []string
	cmp := func(key, want, got string) {
		if want != got {
			diffs = append(diffs, fmt.Sprintf("%s: %q → %q", key, got, want))
		}
	}
	cmp("sso_account_id", d.AccountID, c.Keys["sso_account_id"])
	cmp("sso_role_name", d.RoleName, c.Keys["sso_role_name"])
	cmp("sso_session", d.SSOSession, c.Keys["sso_session"])
	keys := make([]string, 0, len(d.Settings))
	for k := range d.Settings {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		cmp(k, d.Settings[k], c.Keys[k])
	}
	return strings.Join(diffs, ", ")
}

// allowedKeys is the set of keys a managed profile may legitimately carry:
// identity keys plus every key the tool would write (union of desired settings).
func allowedKeys(desired []Profile) map[string]bool {
	allowed := map[string]bool{}
	for k := range IdentityKeys {
		allowed[k] = true
	}
	for _, d := range desired {
		for k := range d.Settings {
			allowed[k] = true
		}
	}
	return allowed
}

// Counts summarizes the plan.
func (p *Plan) Counts() (added, removed, changed, unchanged int) {
	for _, c := range p.Changes {
		switch c.Kind {
		case Added:
			added++
		case Removed:
			removed++
		case Changed:
			changed++
		case Unchanged:
			unchanged++
		}
	}
	return
}

// HasDiff reports whether desired differs from current (add/remove/change).
func (p *Plan) HasDiff() bool {
	a, r, c, _ := p.Counts()
	return a+r+c > 0
}

// HasDrift reports whether the managed block contains hand-edits.
func (p *Plan) HasDrift() bool { return len(p.Drift) > 0 }

// NeedsApply reports whether apply should rewrite the block (a real diff, or
// drift that re-canonicalization will heal).
func (p *Plan) NeedsApply() bool { return p.HasDiff() || p.HasDrift() }

func detectDrift(current []awsconfig.Profile, allowed map[string]bool) []DriftItem {
	var drift []DriftItem
	for _, c := range current {
		var unexpected []string
		for k := range c.Keys {
			if !allowed[k] {
				unexpected = append(unexpected, k)
			}
		}
		if len(unexpected) > 0 {
			sort.Strings(unexpected)
			drift = append(drift, DriftItem{
				Name:   c.Name,
				Reason: "unexpected key(s): " + strings.Join(unexpected, ", "),
			})
		}
	}
	sort.Slice(drift, func(i, j int) bool { return drift[i].Name < drift[j].Name })
	return drift
}
