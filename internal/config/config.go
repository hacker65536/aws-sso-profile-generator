// Package config loads, validates, and resolves the .aws-sso-profiles.yaml
// policy file. The same struct (with json tags) feeds YAML decoding, JSON
// Schema validation, and --output json, so there is a single model.
package config

import (
	"bytes"
	_ "embed"
	"fmt"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
	"sigs.k8s.io/yaml"

	"github.com/hacker65536/aws-sso-profiles/internal/awsconfig"
	"github.com/hacker65536/aws-sso-profiles/internal/naming"
	"github.com/hacker65536/aws-sso-profiles/internal/plan"
	"github.com/hacker65536/aws-sso-profiles/internal/selector"
)

//go:embed schema.json
var schemaJSON []byte

// Config is the policy file model.
type Config struct {
	AWSConfigFile string              `json:"aws_config_file,omitempty"`
	SSO           SSO                 `json:"sso"`
	Defaults      Defaults            `json:"defaults"`
	Select        Select              `json:"select"`
	Overrides     []selector.Override `json:"overrides,omitempty"`
}

// SSO references the [sso-session] block; start_url/region are optional seeds.
type SSO struct {
	Session  string `json:"session,omitempty"`
	StartURL string `json:"start_url,omitempty"`
	Region   string `json:"region,omitempty"`
}

// Defaults holds naming policy and the base profile settings.
type Defaults struct {
	Prefix    string            `json:"prefix,omitempty"`
	Normalize string            `json:"normalize,omitempty"`
	Template  string            `json:"template,omitempty"`
	Settings  map[string]string `json:"settings,omitempty"`
}

// Select holds glob include/exclude rules.
type Select struct {
	Include []selector.Rule `json:"include,omitempty"`
	Exclude []selector.Rule `json:"exclude,omitempty"`
}

// Schema returns the embedded JSON Schema (for the `schema` command).
func Schema() []byte { return schemaJSON }

// Parse validates raw YAML against the schema, unmarshals it, applies defaults,
// and runs semantic checks.
func Parse(data []byte) (*Config, error) {
	if err := validateSchema(data); err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	c.applyDefaults()
	if err := c.semantic(); err != nil {
		return nil, err
	}
	return &c, nil
}

func validateSchema(data []byte) error {
	inst, err := yaml.YAMLToJSON(data)
	if err != nil {
		return fmt.Errorf("config is not valid YAML: %w", err)
	}
	instance, err := jsonschema.UnmarshalJSON(bytes.NewReader(inst))
	if err != nil {
		return fmt.Errorf("config decode: %w", err)
	}
	schemaDoc, err := jsonschema.UnmarshalJSON(bytes.NewReader(schemaJSON))
	if err != nil {
		return fmt.Errorf("internal: bad embedded schema: %w", err)
	}
	c := jsonschema.NewCompiler()
	if err := c.AddResource("schema.json", schemaDoc); err != nil {
		return fmt.Errorf("internal: %w", err)
	}
	sch, err := c.Compile("schema.json")
	if err != nil {
		return fmt.Errorf("internal: %w", err)
	}
	if err := sch.Validate(instance); err != nil {
		return fmt.Errorf("config schema validation failed:\n%v", err)
	}
	return nil
}

func (c *Config) applyDefaults() {
	if c.Defaults.Prefix == "" {
		c.Defaults.Prefix = "awssso"
	}
	if c.Defaults.Normalize == "" {
		c.Defaults.Normalize = string(naming.Minimal)
	}
	if c.Defaults.Template == "" {
		c.Defaults.Template = naming.DefaultTemplate
	}
}

func (c *Config) semantic() error {
	if err := naming.ValidateTemplate(c.Defaults.Template); err != nil {
		return err
	}
	if c.Defaults.Normalize != string(naming.Minimal) && c.Defaults.Normalize != string(naming.Full) {
		return fmt.Errorf("defaults.normalize must be 'minimal' or 'full', got %q", c.Defaults.Normalize)
	}
	if strings.ContainsAny(c.Defaults.Prefix, " \t") {
		return fmt.Errorf("defaults.prefix must not contain whitespace: %q", c.Defaults.Prefix)
	}
	if err := checkSettings("defaults.settings", c.Defaults.Settings); err != nil {
		return err
	}
	for i, ov := range c.Overrides {
		if err := checkSettings(fmt.Sprintf("overrides[%d].settings", i), ov.Settings); err != nil {
			return err
		}
	}
	return nil
}

// checkSettings rejects tool-owned identity keys in a user settings map.
func checkSettings(where string, settings map[string]string) error {
	for k := range settings {
		if plan.IdentityKeys[k] {
			return fmt.Errorf("%s must not set the tool-owned key %q (identity keys are managed automatically)", where, k)
		}
	}
	return nil
}

// ResolvedDefaultSettings builds the base settings for every profile: built-in
// defaults (output=json, cli_pager=), region from ambient fallback, then the
// user's defaults.settings overlaid on top.
func (c *Config) ResolvedDefaultSettings(ambientRegion string) map[string]string {
	base := map[string]string{"output": "json", "cli_pager": ""}
	if ambientRegion != "" {
		base["region"] = ambientRegion
	}
	for k, v := range c.Defaults.Settings {
		base[k] = v
	}
	return base
}

// NormalizeMode returns the resolved normalization mode.
func (c *Config) NormalizeMode() naming.Mode { return naming.Mode(c.Defaults.Normalize) }

// Selector builds the compiled selector.
func (c *Config) Selector() *selector.Selector {
	return selector.New(c.Select.Include, c.Select.Exclude)
}

// OverridesResolver builds the compiled override resolver.
func (c *Config) OverridesResolver() *selector.Overrides {
	return selector.NewOverrides(c.Overrides)
}

// CrossCheck guards against org mix-ups (proposal 4): when the config declares
// sso.start_url/region, they must match the resolved [sso-session] block.
func (c *Config) CrossCheck(s awsconfig.SSOSession) error {
	if c.SSO.StartURL != "" && c.SSO.StartURL != s.StartURL {
		return fmt.Errorf("org mismatch: config sso.start_url=%q but [sso-session %s].sso_start_url=%q — wrong AWS_CONFIG_FILE or session?",
			c.SSO.StartURL, s.Name, s.StartURL)
	}
	if c.SSO.Region != "" && c.SSO.Region != s.Region {
		return fmt.Errorf("org mismatch: config sso.region=%q but [sso-session %s].sso_region=%q",
			c.SSO.Region, s.Name, s.Region)
	}
	return nil
}
