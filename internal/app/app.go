// Package app orchestrates the subcommands: it resolves config + AWS config +
// session, fetches the SSO inventory (or a fake for tests), and drives the
// plan/render/splice pipeline. cmd wires cobra flags to these methods.
package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/hacker65536/aws-sso-profiles/internal/awsconfig"
	"github.com/hacker65536/aws-sso-profiles/internal/config"
	"github.com/hacker65536/aws-sso-profiles/internal/diskcache"
	"github.com/hacker65536/aws-sso-profiles/internal/plan"
	"github.com/hacker65536/aws-sso-profiles/internal/render"
	"github.com/hacker65536/aws-sso-profiles/internal/ssoapi"
	"github.com/hacker65536/aws-sso-profiles/internal/ssotoken"
)

// DefaultConfigPath is used when --config is not given.
const DefaultConfigPath = ".aws-sso-profiles.yaml"

// FakeInventoryEnv, when set to a JSON file path, bypasses AWS entirely and
// loads the inventory from disk. Used by the E2E tests to drive the real binary
// deterministically without network or credentials.
const FakeInventoryEnv = "ASP_FAKE_INVENTORY"

// App is a resolved run context.
type App struct {
	ConfigPath    string
	AWSConfigPath string
	Cfg           *config.Config
	Version       string
	awsContent    string
	configSHA     string
	Session       awsconfig.SSOSession
	Params        plan.Params
}

// Load reads and resolves everything needed to plan/apply (except the token).
// version is stamped into the managed block's provenance header.
func Load(configPath, version string) (*App, error) {
	if configPath == "" {
		configPath = DefaultConfigPath
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", configPath, err)
	}
	sum := sha256.Sum256(data)
	cfg, err := config.Parse(data)
	if err != nil {
		return nil, err
	}

	awsPath := awsconfig.Path()
	if cfg.AWSConfigFile != "" {
		awsPath = expandHome(cfg.AWSConfigFile)
	}
	awsContent, err := readIfExists(awsPath)
	if err != nil {
		return nil, err
	}

	sess, err := awsconfig.SelectSSOSession(awsconfig.ParseSSOSessions(awsContent), cfg.SSO.Session)
	if err != nil {
		return nil, err
	}
	if err := cfg.CrossCheck(sess); err != nil {
		return nil, err
	}

	a := &App{
		ConfigPath:    configPath,
		AWSConfigPath: awsPath,
		Cfg:           cfg,
		Version:       version,
		awsContent:    awsContent,
		configSHA:     hex.EncodeToString(sum[:])[:12],
		Session:       sess,
		Params: plan.Params{
			Prefix:          cfg.Defaults.Prefix,
			SSOSession:      sess.Name,
			Template:        cfg.Defaults.Template,
			Normalize:       cfg.NormalizeMode(),
			DefaultSettings: cfg.ResolvedDefaultSettings(awsconfig.AmbientRegion(awsContent)),
			Selector:        cfg.Selector(),
			Overrides:       cfg.OverridesResolver(),
		},
	}
	return a, nil
}

// InvOptions controls how the inventory is obtained.
type InvOptions struct {
	Parallel int
	Login    bool // run `aws sso login` if the token is expired
	Cache    bool // opt-in on-disk cache
	Refresh  bool // clear the cache and force a live fetch
}

// Inventory returns the reachable accounts×roles, honoring the fake-inventory
// env hook, the opt-in disk cache, and expired-token login.
func (a *App) Inventory(ctx context.Context, opts InvOptions) ([]ssoapi.AccountRoles, error) {
	if fake := os.Getenv(FakeInventoryEnv); fake != "" {
		return loadFakeInventory(fake)
	}

	var cache *diskcache.Cache
	if opts.Cache || opts.Refresh {
		cache = diskcache.New()
		if opts.Refresh {
			_ = cache.Clear()
		} else if inv, ok := cache.Load(a.Session.StartURL); ok {
			return inv, nil
		}
	}

	tok, err := ssotoken.Load(a.Session.Name, a.Session.StartURL)
	if err != nil {
		return nil, err
	}
	if tok.Expired() {
		if !opts.Login {
			return nil, fmt.Errorf("SSO session expired; run: %s", ssotoken.LoginHint(a.Session.Name))
		}
		if err := runLogin(a.Session.Name); err != nil {
			return nil, err
		}
		if tok, err = ssotoken.Load(a.Session.Name, a.Session.StartURL); err != nil {
			return nil, err
		}
	}
	client := ssoapi.NewClient(a.Session.Region, 0)
	inv, err := ssoapi.FetchInventory(ctx, client, tok.AccessToken, opts.Parallel)
	if err != nil {
		return nil, err
	}
	if cache != nil {
		_ = cache.Save(a.Session.StartURL, inv)
	}
	return inv, nil
}

// Plan builds the desired set and diffs it against the current managed block.
func (a *App) Plan(inv []ssoapi.AccountRoles) (*plan.Plan, []plan.Profile, error) {
	desired, err := plan.BuildDesired(inv, a.Params)
	if err != nil {
		return nil, nil, err
	}
	current := awsconfig.ParseProfiles(a.currentBody())
	return plan.Diff(desired, current), desired, nil
}

func (a *App) currentBody() string {
	body, _, _ := awsconfig.ExtractBlockBody(a.awsContent, a.Params.Prefix)
	return body
}

// Apply writes the managed block when there is a diff. The no-op decision is
// plan-based (not byte-based) so version/provenance churn never triggers a
// rewrite: identical desired profiles ⇒ no write ⇒ byte-stable file (§0).
func (a *App) Apply(desired []plan.Profile, hasDiff bool) (changed bool, backup string, err error) {
	if !hasDiff {
		return false, "", nil
	}
	prov := render.Provenance{Version: a.Version, ConfigSHA: a.configSHA}
	desiredBody := render.Body(desired, prov)
	newContent, err := awsconfig.SpliceBlock(a.awsContent, a.Params.Prefix, desiredBody, awsconfig.NowStamp())
	if err != nil {
		return false, "", err
	}
	if bak, err := awsconfig.Backup(a.AWSConfigPath, 10); err == nil {
		backup = bak
	} else {
		return false, "", err
	}
	if err := awsconfig.WriteAtomic(a.AWSConfigPath, newContent); err != nil {
		return false, "", err
	}
	a.awsContent = newContent
	return true, backup, nil
}

// Cleanup removes the managed block for this prefix. Returns whether it changed.
func (a *App) Cleanup() (changed bool, backup string, err error) {
	newContent, err := awsconfig.RemoveBlock(a.awsContent, a.Params.Prefix)
	if err != nil {
		return false, "", err
	}
	if newContent == a.awsContent {
		return false, "", nil
	}
	if bak, err := awsconfig.Backup(a.AWSConfigPath, 10); err == nil {
		backup = bak
	} else {
		return false, "", err
	}
	if err := awsconfig.WriteAtomic(a.AWSConfigPath, newContent); err != nil {
		return false, "", err
	}
	a.awsContent = newContent
	return true, backup, nil
}

// CleanupSession removes only the profiles in this prefix's managed block whose
// sso_session matches session, re-rendering the block with the rest (bash
// --session parity). If none remain, the block is removed entirely.
func (a *App) CleanupSession(session string) (changed bool, backup string, err error) {
	current := awsconfig.ParseProfiles(a.currentBody())
	if len(current) == 0 {
		return false, "", nil
	}
	var kept []plan.Profile
	for _, p := range current {
		if p.Keys["sso_session"] == session {
			continue
		}
		settings := map[string]string{}
		for k, v := range p.Keys {
			if !plan.IdentityKeys[k] {
				settings[k] = v
			}
		}
		kept = append(kept, plan.Profile{
			Name:       p.Name,
			SSOSession: p.Keys["sso_session"],
			AccountID:  p.Keys["sso_account_id"],
			RoleName:   p.Keys["sso_role_name"],
			Settings:   settings,
		})
	}
	if len(kept) == len(current) {
		return false, "", nil // nothing matched
	}

	var newContent string
	if len(kept) == 0 {
		newContent, err = awsconfig.RemoveBlock(a.awsContent, a.Params.Prefix)
	} else {
		prov := render.Provenance{Version: a.Version, ConfigSHA: a.configSHA}
		newContent, err = awsconfig.SpliceBlock(a.awsContent, a.Params.Prefix, render.Body(kept, prov), awsconfig.NowStamp())
	}
	if err != nil {
		return false, "", err
	}
	if bak, err := awsconfig.Backup(a.AWSConfigPath, 10); err == nil {
		backup = bak
	} else {
		return false, "", err
	}
	if err := awsconfig.WriteAtomic(a.AWSConfigPath, newContent); err != nil {
		return false, "", err
	}
	a.awsContent = newContent
	return true, backup, nil
}

// AWSContent returns the current AWS config file content (for the check command).
func (a *App) AWSContent() string { return a.awsContent }

// Prefix returns the resolved profile prefix / org id.
func (a *App) Prefix() string { return a.Params.Prefix }

func loadFakeInventory(path string) ([]ssoapi.AccountRoles, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read fake inventory: %w", err)
	}
	var inv []ssoapi.AccountRoles
	if err := json.Unmarshal(data, &inv); err != nil {
		return nil, fmt.Errorf("parse fake inventory: %w", err)
	}
	return inv, nil
}

func runLogin(session string) error {
	cmd := exec.Command("aws", "sso", "login", "--sso-session", session)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	// Drop AWS_PROFILE: if it points at a profile absent from this org's config,
	// `aws sso login` fails to resolve it before even starting the flow.
	cmd.Env = withoutEnv(os.Environ(), "AWS_PROFILE")
	return cmd.Run()
}

// withoutEnv returns environ with any KEY=... entries for key removed.
func withoutEnv(environ []string, key string) []string {
	prefix := key + "="
	out := environ[:0:0]
	for _, kv := range environ {
		if !strings.HasPrefix(kv, prefix) {
			out = append(out, kv)
		}
	}
	return out
}

func readIfExists(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return string(data), nil
}

func expandHome(p string) string {
	if p == "~" {
		home, _ := os.UserHomeDir()
		return home
	}
	if strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}
