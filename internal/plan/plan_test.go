package plan

import (
	"strings"
	"testing"

	"github.com/hacker65536/aws-sso-profiles/internal/awsconfig"
	"github.com/hacker65536/aws-sso-profiles/internal/naming"
	"github.com/hacker65536/aws-sso-profiles/internal/selector"
	"github.com/hacker65536/aws-sso-profiles/internal/ssoapi"
)

func params() Params {
	return Params{
		Prefix:          "awssso",
		SSOSession:      "my-sso",
		Template:        naming.DefaultTemplate,
		Normalize:       naming.Minimal,
		DefaultSettings: map[string]string{"region": "us-east-1", "output": "json", "cli_pager": ""},
		Selector:        selector.New(nil, nil),
		Overrides:       selector.NewOverrides(nil),
	}
}

func inv() []ssoapi.AccountRoles {
	return []ssoapi.AccountRoles{
		{Account: ssoapi.Account{ID: "1", Name: "acct one"}, Roles: []string{"AWSReadOnlyAccess", "AWSAdministratorAccess"}},
		{Account: ssoapi.Account{ID: "2", Name: "acct two"}, Roles: []string{"AWSReadOnlyAccess"}},
	}
}

func TestBuildDesired(t *testing.T) {
	d, err := BuildDesired(inv(), params())
	if err != nil {
		t.Fatal(err)
	}
	if len(d) != 3 {
		t.Fatalf("got %d desired, want 3", len(d))
	}
	// Sorted by name; check naming format for one.
	found := false
	for _, p := range d {
		if p.Name == "awssso-acct_one-1:AWSReadOnlyAccess" {
			found = true
			if p.Settings["region"] != "us-east-1" || p.SSOSession != "my-sso" || p.AccountID != "1" {
				t.Errorf("unexpected profile fields: %+v", p)
			}
		}
	}
	if !found {
		t.Errorf("expected profile name not present: %+v", d)
	}
}

func TestBuildDesiredRejectsInjection(t *testing.T) {
	cases := []struct {
		name string
		inv  []ssoapi.AccountRoles
	}{
		{"role newline", []ssoapi.AccountRoles{{Account: ssoapi.Account{ID: "1", Name: "acct"},
			Roles: []string{"Admin\n[profile evil]\ncredential_process = /bin/sh"}}}},
		{"role bracket", []ssoapi.AccountRoles{{Account: ssoapi.Account{ID: "1", Name: "acct"},
			Roles: []string{"Ad]min"}}}},
		{"account id non-digit", []ssoapi.AccountRoles{{Account: ssoapi.Account{ID: "12a", Name: "acct"},
			Roles: []string{"Admin"}}}},
	}
	for _, tc := range cases {
		if _, err := BuildDesired(tc.inv, params()); err == nil {
			t.Errorf("%s: expected validation error, got none", tc.name)
		}
	}
}

func TestBuildDesiredCollision(t *testing.T) {
	p := params()
	p.Template = "{prefix}-{account_name}" // drops account_id + role → guaranteed collisions
	if _, err := BuildDesired(inv(), p); err == nil {
		t.Error("expected collision error when template lacks unique tokens")
	}
}

func TestDiffAddedRemovedChangedUnchanged(t *testing.T) {
	rs := func(r string) map[string]string { return map[string]string{"region": r} }
	desired := []Profile{
		{Name: "awssso-a-1:RO", SSOSession: "my-sso", AccountID: "1", RoleName: "RO", Settings: rs("us-east-1")},      // unchanged
		{Name: "awssso-b-2:RO", SSOSession: "my-sso", AccountID: "2", RoleName: "RO", Settings: rs("ap-northeast-1")}, // changed region
		{Name: "awssso-c-3:RO", SSOSession: "my-sso", AccountID: "3", RoleName: "RO", Settings: rs("us-east-1")},      // added
	}
	current := []awsconfig.Profile{
		{Name: "awssso-a-1:RO", Keys: map[string]string{"sso_account_id": "1", "sso_role_name": "RO", "region": "us-east-1", "sso_session": "my-sso"}},
		{Name: "awssso-b-2:RO", Keys: map[string]string{"sso_account_id": "2", "sso_role_name": "RO", "region": "us-east-1", "sso_session": "my-sso"}},
		{Name: "awssso-z-9:RO", Keys: map[string]string{"sso_account_id": "9", "sso_role_name": "RO", "region": "us-east-1", "sso_session": "my-sso"}}, // removed
	}
	pl := Diff(desired, current)
	a, r, c, u := pl.Counts()
	if a != 1 || r != 1 || c != 1 || u != 1 {
		t.Fatalf("counts added=%d removed=%d changed=%d unchanged=%d, want 1/1/1/1", a, r, c, u)
	}
	if !pl.HasDiff() {
		t.Error("HasDiff should be true")
	}
}

func TestDriftUnexpectedKey(t *testing.T) {
	desired := []Profile{{Name: "x", SSOSession: "s", AccountID: "1", RoleName: "RO", Settings: map[string]string{"region": "r"}}}
	current := []awsconfig.Profile{{Name: "x", Keys: map[string]string{
		"sso_account_id": "1", "sso_role_name": "RO", "region": "r", "sso_session": "s",
		"role_arn": "arn:aws:iam::1:role/hand-added", // hand-edit
	}}}
	pl := Diff(desired, current)
	if !pl.HasDrift() {
		t.Fatal("expected drift for unexpected key")
	}
	if pl.HasDiff() {
		t.Error("canonical fields match, so no add/remove/change diff")
	}
	if !pl.NeedsApply() {
		t.Error("drift alone should require apply to heal it")
	}
	if pl.Drift[0].Name != "x" || !strings.Contains(pl.Drift[0].Reason, "role_arn") {
		t.Errorf("unexpected drift item: %+v", pl.Drift[0])
	}
}

func TestDiffNoChange(t *testing.T) {
	desired := []Profile{{Name: "x", SSOSession: "s", AccountID: "1", RoleName: "RO", Settings: map[string]string{"region": "r"}}}
	current := []awsconfig.Profile{{Name: "x", Keys: map[string]string{"sso_account_id": "1", "sso_role_name": "RO", "region": "r", "sso_session": "s"}}}
	pl := Diff(desired, current)
	if pl.HasDiff() {
		t.Error("expected no diff")
	}
}
