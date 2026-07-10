package awsconfig

import (
	"strings"
	"testing"
)

const sampleConfig = `[default]
region = ap-northeast-1

[sso-session my-sso]
sso_start_url = https://x.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile hand-written]
region = us-west-2
sso_session = my-sso
`

func TestParseAndSelectSSOSession(t *testing.T) {
	sessions := ParseSSOSessions(sampleConfig)
	if len(sessions) != 1 {
		t.Fatalf("got %d sessions, want 1", len(sessions))
	}
	s, err := SelectSSOSession(sessions, "")
	if err != nil {
		t.Fatal(err)
	}
	if s.Name != "my-sso" || s.Region != "us-east-1" || s.StartURL != "https://x.awsapps.com/start" {
		t.Errorf("unexpected session: %+v", s)
	}
	if _, err := SelectSSOSession(sessions, "nope"); err == nil {
		t.Error("expected error for missing session")
	}
}

func TestSelectFirstOfMany(t *testing.T) {
	cfg := "[sso-session a]\nsso_region = r1\n\n[sso-session b]\nsso_region = r2\n"
	s, err := SelectSSOSession(ParseSSOSessions(cfg), "")
	if err != nil || s.Name != "a" {
		t.Fatalf("first-in-file expected 'a', got %+v (err %v)", s, err)
	}
}

func TestAmbientRegionFromDefault(t *testing.T) {
	t.Setenv("AWS_REGION", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	if r := AmbientRegion(sampleConfig); r != "ap-northeast-1" {
		t.Errorf("ambient region = %q, want ap-northeast-1", r)
	}
	t.Setenv("AWS_REGION", "eu-west-1")
	if r := AmbientRegion(sampleConfig); r != "eu-west-1" {
		t.Errorf("AWS_REGION should win, got %q", r)
	}
}

const body1 = `# generator=v0 config-sha256=abc
[profile awssso-a-1:RO]
sso_session = my-sso
sso_account_id = 1
sso_role_name = RO
region = us-east-1
output = json
cli_pager =`

func TestSpliceInsertExtractRoundTrip(t *testing.T) {
	out, err := SpliceBlock(sampleConfig, "awssso", body1, "2026/07/09 12:00:00")
	if err != nil {
		t.Fatal(err)
	}
	// Head is preserved verbatim.
	if !strings.HasPrefix(out, sampleConfig) && !strings.Contains(out, "[profile hand-written]") {
		t.Fatal("original content not preserved")
	}
	// Markers present and balanced.
	if strings.Count(out, markerPrefix+"awssso START") != 1 || strings.Count(out, markerPrefix+"awssso END") != 1 {
		t.Fatalf("expected exactly one START/END pair:\n%s", out)
	}
	// Body round-trips exactly.
	got, found, err := ExtractBlockBody(out, "awssso")
	if err != nil || !found {
		t.Fatalf("extract failed: found=%v err=%v", found, err)
	}
	if got != body1 {
		t.Errorf("body round-trip mismatch:\n got=%q\nwant=%q", got, body1)
	}
}

func TestSpliceIsIdempotentBodyEquality(t *testing.T) {
	out1, _ := SpliceBlock(sampleConfig, "awssso", body1, "2026/07/09 12:00:00")
	// Re-splicing the SAME body (different datetime) yields identical body; the
	// apply layer uses body equality to decide no-op.
	b1, _, _ := ExtractBlockBody(out1, "awssso")
	out2, _ := SpliceBlock(out1, "awssso", body1, "2099/01/01 00:00:00")
	b2, _, _ := ExtractBlockBody(out2, "awssso")
	if b1 != b2 {
		t.Errorf("body should be stable across re-splice:\n%q\n%q", b1, b2)
	}
}

func TestPrefixScopingIndependent(t *testing.T) {
	out, _ := SpliceBlock(sampleConfig, "awssso", body1, "t1")
	bodyPoc := "# generator=v0 config-sha256=def\n[profile awspoc-a-1:Admin]\nregion = us-west-2"
	out, err := SpliceBlock(out, "awspoc", bodyPoc, "t2")
	if err != nil {
		t.Fatal(err)
	}
	// Both blocks coexist.
	if _, f, _ := ExtractBlockBody(out, "awssso"); !f {
		t.Error("awssso block lost")
	}
	if _, f, _ := ExtractBlockBody(out, "awspoc"); !f {
		t.Error("awspoc block missing")
	}
	// Removing awspoc leaves awssso intact.
	out2, err := RemoveBlock(out, "awspoc")
	if err != nil {
		t.Fatal(err)
	}
	if _, f, _ := ExtractBlockBody(out2, "awspoc"); f {
		t.Error("awspoc block should be gone")
	}
	if b, f, _ := ExtractBlockBody(out2, "awssso"); !f || b != body1 {
		t.Error("awssso block must be untouched by awspoc removal")
	}
}

func TestUnbalancedMarkersError(t *testing.T) {
	bad := sampleConfig + "\n" + markerPrefix + "awssso START t\n[profile x]\n"
	if _, _, _, err := findBlockRange(mustLines(bad), "awssso"); err == nil {
		t.Error("expected unbalanced-marker error")
	}
}

func TestParseProfiles(t *testing.T) {
	profs := ParseProfiles(body1)
	if len(profs) != 1 {
		t.Fatalf("got %d profiles, want 1", len(profs))
	}
	p := profs[0]
	if p.Name != "awssso-a-1:RO" || p.Keys["sso_account_id"] != "1" || p.Keys["region"] != "us-east-1" {
		t.Errorf("unexpected profile parse: %+v", p)
	}
}

func TestEnsureSSOSession(t *testing.T) {
	out, added := EnsureSSOSession("[default]\nregion = us-east-1\n",
		SSOSession{Name: "new", Region: "us-east-1", StartURL: "https://n/start"}, "sso:account:access")
	if !added || !strings.Contains(out, "[sso-session new]") {
		t.Fatalf("session not added:\n%s", out)
	}
	out2, added2 := EnsureSSOSession(out, SSOSession{Name: "new"}, "sso:account:access")
	if added2 || out2 != out {
		t.Error("EnsureSSOSession must be idempotent for existing session")
	}
}

func TestAllAndManagedProfileNames(t *testing.T) {
	out, _ := SpliceBlock(sampleConfig, "awssso", body1, "t")
	all := AllProfileNames(out)
	if len(all) != 2 { // hand-written + one managed
		t.Fatalf("AllProfileNames = %v, want 2", all)
	}
	managed := ManagedProfileNames(out)
	if !managed["awssso-a-1:RO"] || managed["hand-written"] {
		t.Errorf("ManagedProfileNames wrong: %v", managed)
	}
}

func mustLines(s string) []string {
	lines, _ := splitLines(s)
	return lines
}
