package render

import (
	"flag"
	"os"
	"path/filepath"
	"testing"

	"github.com/hacker65536/aws-sso-profile-generator/internal/plan"
)

var update = flag.Bool("update", false, "update golden files")

func sample() []plan.Profile {
	std := func(region string) map[string]string {
		return map[string]string{"region": region, "output": "json", "cli_pager": ""}
	}
	// Deliberately unsorted input to prove Body sorts.
	return []plan.Profile{
		{Name: "awssso-b-2:AWSReadOnlyAccess", SSOSession: "my-sso", AccountID: "2", RoleName: "AWSReadOnlyAccess", Settings: std("us-east-1")},
		{Name: "awssso-a-1:AWSAdministratorAccess", SSOSession: "my-sso", AccountID: "1", RoleName: "AWSAdministratorAccess", Settings: std("ap-northeast-1")},
	}
}

var testProv = Provenance{Version: "v-test", ConfigSHA: "deadbeef"}

func TestBodyGolden(t *testing.T) {
	got := Body(sample(), testProv)
	golden := filepath.Join("testdata", "basic.golden")
	if *update {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(golden, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden (run with -update first): %v", err)
	}
	if got != string(want) {
		t.Errorf("body mismatch:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

func TestBodyDeterministic(t *testing.T) {
	if Body(sample(), testProv) != Body(sample(), testProv) {
		t.Error("Body must be deterministic")
	}
}

func TestBodyKeyOrderAndLayout(t *testing.T) {
	// Identity keys fixed first, then settings sorted by key (cli_pager, output, region).
	got := Body([]plan.Profile{{Name: "n", SSOSession: "s", AccountID: "1", RoleName: "R",
		Settings: map[string]string{"region": "r", "output": "json", "cli_pager": ""}}}, testProv)
	want := Header(testProv) + "\n\n[profile n]\nsso_session = s\nsso_account_id = 1\nsso_role_name = R\ncli_pager =\noutput = json\nregion = r"
	if got != want {
		t.Errorf("layout mismatch:\n got=%q\nwant=%q", got, want)
	}
}

func TestBodyEmpty(t *testing.T) {
	if Body(nil, testProv) != Header(testProv) {
		t.Errorf("empty body should be just the header, got %q", Body(nil, testProv))
	}
}
