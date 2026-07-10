package config

import (
	"strings"
	"testing"

	"github.com/hacker65536/aws-sso-profiles/internal/awsconfig"
)

const good = `
aws_config_file: ~/.aws/config.poc
sso:
  session: my-sso
  start_url: https://x/start
  region: us-east-1
defaults:
  prefix: awspoc
  normalize: full
  template: "{prefix}-{account_name}-{account_id}:{role}"
  settings:
    region: us-east-1
    output: yaml
    duration_seconds: "3600"
select:
  include:
    - { account: "*", role: "*" }
  exclude:
    - { account: "*sandbox*", role: "*" }
overrides:
  - match: { account: "prod-*", role: "*" }
    settings:
      region: ap-northeast-1
`

func TestParseGood(t *testing.T) {
	c, err := Parse([]byte(good))
	if err != nil {
		t.Fatal(err)
	}
	if c.Defaults.Prefix != "awspoc" || c.NormalizeMode() != "full" {
		t.Errorf("unexpected defaults: %+v", c.Defaults)
	}
	if len(c.Select.Exclude) != 1 || len(c.Overrides) != 1 {
		t.Errorf("select/overrides not parsed: %+v", c)
	}
	if c.Defaults.Settings["output"] != "yaml" || c.Defaults.Settings["duration_seconds"] != "3600" {
		t.Errorf("settings not parsed: %+v", c.Defaults.Settings)
	}
}

func TestResolvedDefaultSettings(t *testing.T) {
	c, _ := Parse([]byte(good))
	s := c.ResolvedDefaultSettings("ap-northeast-1")
	// user output=yaml overrides built-in json; ambient region overridden by settings region
	if s["output"] != "yaml" || s["region"] != "us-east-1" || s["cli_pager"] != "" {
		t.Errorf("resolved settings wrong: %+v", s)
	}
	// ambient used when settings omit region
	c2, _ := Parse([]byte("sso:\n  session: s\n"))
	if c2.ResolvedDefaultSettings("eu-west-1")["region"] != "eu-west-1" {
		t.Error("ambient region fallback failed")
	}
}

func TestSettingsRejectsIdentityKey(t *testing.T) {
	_, err := Parse([]byte("defaults:\n  settings:\n    sso_session: hacked\n"))
	if err == nil {
		t.Error("expected error for identity key in settings")
	}
}

func TestSettingsRejectsNonStringValue(t *testing.T) {
	// unquoted number must fail schema (values must be strings)
	_, err := Parse([]byte("defaults:\n  settings:\n    duration_seconds: 3600\n"))
	if err == nil {
		t.Error("expected schema error for non-string settings value")
	}
}

func TestDefaultsApplied(t *testing.T) {
	c, err := Parse([]byte("sso:\n  session: s\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Defaults.Prefix != "awssso" || c.Defaults.Normalize != "minimal" || c.Defaults.Template == "" {
		t.Errorf("defaults not applied: %+v", c.Defaults)
	}
}

func TestSchemaRejectsUnknownKey(t *testing.T) {
	_, err := Parse([]byte("defaults:\n  prefx: typo\n"))
	if err == nil {
		t.Error("expected schema error for unknown key 'prefx'")
	}
}

func TestSchemaRejectsBadNormalize(t *testing.T) {
	_, err := Parse([]byte("defaults:\n  normalize: sideways\n"))
	if err == nil {
		t.Error("expected enum error for normalize")
	}
}

func TestSemanticRejectsBadTemplate(t *testing.T) {
	_, err := Parse([]byte(`defaults:
  template: "{prefix}-{bogus}"
`))
	if err == nil || !strings.Contains(err.Error(), "template") {
		t.Errorf("expected template variable error, got %v", err)
	}
}

func TestCrossCheck(t *testing.T) {
	c, _ := Parse([]byte(good))
	ok := awsconfig.SSOSession{Name: "my-sso", StartURL: "https://x/start", Region: "us-east-1"}
	if err := c.CrossCheck(ok); err != nil {
		t.Errorf("cross-check should pass: %v", err)
	}
	wrong := awsconfig.SSOSession{Name: "my-sso", StartURL: "https://OTHER/start", Region: "us-east-1"}
	if err := c.CrossCheck(wrong); err == nil {
		t.Error("cross-check should fail on start_url mismatch")
	}
}
