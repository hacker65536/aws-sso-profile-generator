package naming

import "testing"

func TestNormalizeMinimal(t *testing.T) {
	// Expectations ported from test/test_units.sh (bash parity).
	cases := []struct{ in, want string }{
		{"My Perfect-Web-Service Prod", "My_Perfect-Web-Service_Prod"}, // space->_, hyphen+case kept
		{"acct-one", "acct-one"},       // hyphen preserved
		{"a  b", "a__b"},               // consecutive spaces
		{"abc!@#$%^&*()123", "abc123"}, // specials stripped
		{"数字123Account", "123Account"}, // non-ASCII dropped, case kept
		{"", ""},
	}
	for _, c := range cases {
		if got := Normalize(c.in, Minimal); got != c.want {
			t.Errorf("Normalize(%q, Minimal) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeFull(t *testing.T) {
	cases := []struct{ in, want string }{
		{"My Perfect-Web-Service Prod", "my_perfect_web_service_prod"}, // lowercase + hyphen->_
		{"acct-one", "acct_one"},
		{"数字123Account", "123account"}, // non-ASCII dropped, lowercased
		{"a  b", "a__b"},
		{"ABC-def GHI", "abc_def_ghi"},
		{"", ""},
	}
	for _, c := range cases {
		if got := Normalize(c.in, Full); got != c.want {
			t.Errorf("Normalize(%q, Full) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeUnknownModeFallsBackToMinimal(t *testing.T) {
	if got := Normalize("My-Name", Mode("bogus")); got != "My-Name" {
		t.Errorf("unknown mode = %q, want minimal behavior %q", got, "My-Name")
	}
}

func TestProfileNameDefaultTemplate(t *testing.T) {
	got, err := ProfileName(DefaultTemplate, "awssso", "acct one", "100000000001", "AWSReadOnlyAccess", Minimal)
	if err != nil {
		t.Fatal(err)
	}
	want := "awssso-acct_one-100000000001:AWSReadOnlyAccess"
	if got != want {
		t.Errorf("ProfileName = %q, want %q", got, want)
	}
}

func TestValidateTemplate(t *testing.T) {
	if err := ValidateTemplate(DefaultTemplate); err != nil {
		t.Errorf("default template should be valid: %v", err)
	}
	if err := ValidateTemplate("{prefix}-{acct}"); err == nil {
		t.Error("expected error for unknown variable {acct}")
	}
}

func TestExpandUnknownVariable(t *testing.T) {
	if _, err := Expand("{prefix}-{nope}", map[string]string{"prefix": "x"}); err == nil {
		t.Error("expected error for unknown variable in Expand")
	}
}
