package selector

import "testing"

func TestSelectedIncludeExclude(t *testing.T) {
	s := New(
		[]Rule{{Account: "*", Role: "*"}},
		[]Rule{{Account: "*sandbox*", Role: "*"}, {Account: "*", Role: "AWSReadOnlyAccess"}},
	)
	cases := []struct {
		acct, role string
		want       bool
	}{
		{"prod-1", "AWSAdministratorAccess", true},
		{"my-sandbox-2", "AWSAdministratorAccess", false}, // excluded by account
		{"prod-1", "AWSReadOnlyAccess", false},            // excluded by role
	}
	for _, c := range cases {
		if got := s.Selected(c.acct, c.role); got != c.want {
			t.Errorf("Selected(%q,%q)=%v want %v", c.acct, c.role, got, c.want)
		}
	}
}

func TestEmptyIncludeMeansAll(t *testing.T) {
	s := New(nil, nil)
	if !s.Selected("anything", "any-role") {
		t.Error("empty include should select everything")
	}
}

func TestOverridesFirstMatchWins(t *testing.T) {
	o := NewOverrides([]Override{
		{Match: Rule{Account: "prod-*", Role: "*"}, Settings: map[string]string{"region": "ap-northeast-1"}},
		{Match: Rule{Account: "*", Role: "*"}, Settings: map[string]string{"region": "us-east-1"}},
	})
	if s := o.Settings("prod-1", "Admin"); s["region"] != "ap-northeast-1" {
		t.Errorf("prod override = %v", s)
	}
	if s := o.Settings("dev-1", "Admin"); s["region"] != "us-east-1" {
		t.Errorf("fallback override = %v", s)
	}
	if s := (*Overrides)(nil).Settings("x", "y"); s != nil {
		t.Error("nil overrides should not match")
	}
}

func TestQuestionMarkGlob(t *testing.T) {
	s := New([]Rule{{Account: "acct-?", Role: "*"}}, nil)
	if !s.Selected("acct-1", "r") {
		t.Error("acct-? should match acct-1")
	}
	if s.Selected("acct-12", "r") {
		t.Error("acct-? should not match acct-12")
	}
}
