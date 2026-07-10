// Command aws-sso-profiles is a desired-state CLI that generates AWS SSO
// profiles into ~/.aws/config from a declarative .aws-sso-profiles.yaml.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/spf13/cobra"

	"github.com/hacker65536/aws-sso-profiles/internal/app"
	"github.com/hacker65536/aws-sso-profiles/internal/awsconfig"
	"github.com/hacker65536/aws-sso-profiles/internal/config"
	"github.com/hacker65536/aws-sso-profiles/internal/plan"
)

// version, commit and date are overridden at build time via
// -ldflags "-X main.version=... -X main.commit=... -X main.date=...".
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

var exitCode int

func main() { os.Exit(run()) }

// run executes the CLI and returns the process exit code. Split from main so
// the E2E tests can invoke it in-process via testscript.
func run() int {
	exitCode = 0 // reset: testscript reuses the process across invocations
	if err := rootCmd().Execute(); err != nil {
		if exitCode == 0 {
			exitCode = 1
		}
	}
	return exitCode
}

func rootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "aws-sso-profiles",
		Short:         "Desired-state generator for AWS SSO profiles",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: false,
	}
	root.PersistentFlags().StringP("config", "c", app.DefaultConfigPath, "path to .aws-sso-profiles.yaml (env: AWS_SSO_PROFILES_CONFIG)")
	root.PersistentFlags().StringP("output", "o", "human", "output format: human|json")
	root.AddCommand(initCmd(), listCmd(), planCmd(), applyCmd(), validateCmd(), schemaCmd(), cleanupCmd(), checkCmd(), versionCmd())
	return root
}

// ---- helpers ----

func loadApp(cmd *cobra.Command) (*app.App, error) {
	return app.Load(configPath(cmd), version)
}

// configPath resolves the config file path with precedence:
// explicit --config > $AWS_SSO_PROFILES_CONFIG > flag default.
func configPath(cmd *cobra.Command) string {
	if cmd.Flags().Changed("config") {
		v, _ := cmd.Flags().GetString("config")
		return v
	}
	if env := os.Getenv(app.ConfigPathEnv); env != "" {
		return env
	}
	v, _ := cmd.Flags().GetString("config")
	return v
}

func invOptions(cmd *cobra.Command) app.InvOptions {
	par, _ := cmd.Flags().GetInt("parallel")
	login, _ := cmd.Flags().GetBool("login")
	cache, _ := cmd.Flags().GetBool("cache")
	refresh, _ := cmd.Flags().GetBool("refresh-cache")
	return app.InvOptions{Parallel: par, Login: login, Cache: cache, Refresh: refresh}
}

func addInventoryFlags(c *cobra.Command) {
	c.Flags().IntP("parallel", "p", 8, "concurrent ListAccountRoles calls")
	c.Flags().Bool("login", false, "run `aws sso login` if the token is expired")
	c.Flags().Bool("cache", false, "use the opt-in on-disk inventory cache")
	c.Flags().Bool("refresh-cache", false, "clear the cache and force a live fetch")
}

// ---- init ----

func initCmd() *cobra.Command {
	var session, startURL, region, prefix, scopes, awsFile string
	var force bool
	c := &cobra.Command{
		Use:   "init",
		Short: "Interactively create .aws-sso-profiles.yaml and the [sso-session] block",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfgPath := configPath(cmd)
			// Guard: never clobber an existing config without --force.
			if !force {
				if _, err := os.Stat(cfgPath); err == nil {
					return fmt.Errorf("%s already exists; pass --force to overwrite", cfgPath)
				}
			}

			r := bufio.NewReader(cmd.InOrStdin())
			session = promptIfEmpty(cmd, r, "SSO session name", session)
			startURL = promptIfEmpty(cmd, r, "SSO start URL", startURL)
			region = promptIfEmpty(cmd, r, "SSO region", region)
			if prefix == "" {
				prefix = "awssso"
			}
			if scopes == "" {
				scopes = "sso:account:access"
			}
			if session == "" || startURL == "" || region == "" {
				return fmt.Errorf("session, start-url and region are required")
			}

			// Ensure the [sso-session] block exists (seed → authoritative source).
			awsPath := awsconfig.Path()
			if awsFile != "" {
				awsPath = awsFile
			}
			content, _ := os.ReadFile(awsPath)
			newContent, added := awsconfig.EnsureSSOSession(string(content),
				awsconfig.SSOSession{Name: session, Region: region, StartURL: startURL}, scopes)
			if added {
				if err := awsconfig.WriteAtomic(awsPath, newContent); err != nil {
					return err
				}
				fmt.Fprintf(cmd.OutOrStdout(), "Wrote [sso-session %s] to %s\n", session, awsPath)
			}

			if err := os.WriteFile(cfgPath, []byte(initYAML(awsFile, session, startURL, region, prefix)), 0o644); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Wrote %s\n", cfgPath)
			fmt.Fprintf(cmd.OutOrStdout(), "Next: aws sso login --sso-session %s\n", session)
			return nil
		},
	}
	c.Flags().StringVar(&session, "session", "", "SSO session name")
	c.Flags().StringVar(&startURL, "start-url", "", "SSO start URL (admin-provided)")
	c.Flags().StringVar(&region, "region", "", "SSO region (admin-provided)")
	c.Flags().StringVar(&prefix, "prefix", "", "profile prefix / org id (default awssso)")
	c.Flags().StringVar(&scopes, "scopes", "", "sso_registration_scopes (default sso:account:access)")
	c.Flags().StringVar(&awsFile, "aws-config", "", "target AWS config file (defaults to ~/.aws/config)")
	c.Flags().BoolVar(&force, "force", false, "overwrite an existing config file")
	return c
}

func initYAML(awsFile, session, startURL, region, prefix string) string {
	var b strings.Builder
	if awsFile != "" {
		fmt.Fprintf(&b, "aws_config_file: %s\n", awsFile)
	}
	fmt.Fprintf(&b, `sso:
  session: %s
  start_url: %s
  region: %s
defaults:
  prefix: %s
  normalize: minimal
  template: "{prefix}-{account_name}-{account_id}:{role}"
select:
  include:
    - { account: "*", role: "*" }
`, session, startURL, region, prefix)
	return b.String()
}

func promptIfEmpty(cmd *cobra.Command, r *bufio.Reader, label, cur string) string {
	if cur != "" {
		return cur
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s: ", label)
	line, _ := r.ReadString('\n')
	return strings.TrimSpace(line)
}

// ---- list ----

func listCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "list",
		Short: "List reachable accounts and roles (no profiles written)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			inv, err := a.Inventory(context.Background(), invOptions(cmd))
			if err != nil {
				return err
			}
			out, _ := cmd.Flags().GetString("output")
			if out == "json" {
				return writeJSON(cmd, inv)
			}
			for _, ar := range inv {
				fmt.Fprintf(cmd.OutOrStdout(), "%s (%s)\n", ar.Account.Name, ar.Account.ID)
				for _, r := range ar.Roles {
					fmt.Fprintf(cmd.OutOrStdout(), "  - %s\n", r)
				}
			}
			return nil
		},
	}
	addInventoryFlags(c)
	return c
}

// ---- plan ----

func planCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "plan",
		Short: "Show the diff between desired and current profiles (exit 2 if diff)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			inv, err := a.Inventory(context.Background(), invOptions(cmd))
			if err != nil {
				return err
			}
			pl, _, err := a.Plan(inv)
			if err != nil {
				return err
			}
			out, _ := cmd.Flags().GetString("output")
			if err := reportPlan(cmd, pl, out); err != nil {
				return err
			}
			if pl.NeedsApply() {
				exitCode = 2
			}
			return nil
		},
	}
	addInventoryFlags(c)
	return c
}

// ---- apply ----

func applyCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "apply",
		Short: "Idempotently write the managed block to match desired state",
		RunE: func(cmd *cobra.Command, _ []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			inv, err := a.Inventory(context.Background(), invOptions(cmd))
			if err != nil {
				return err
			}
			pl, desired, err := a.Plan(inv)
			if err != nil {
				return err
			}
			out, _ := cmd.Flags().GetString("output")
			if err := reportPlan(cmd, pl, out); err != nil {
				return err
			}
			changed, backup, err := a.Apply(desired, pl.NeedsApply())
			if err != nil {
				return err
			}
			if out != "json" {
				if changed {
					fmt.Fprintf(cmd.OutOrStdout(), "Applied. Backup: %s\n", backup)
				} else {
					fmt.Fprintln(cmd.OutOrStdout(), "No changes. Config unchanged.")
				}
			}
			return nil
		},
	}
	addInventoryFlags(c)
	return c
}

// ---- validate ----

func validateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate",
		Short: "Validate the config (schema + semantics + org cross-check)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "OK: config valid; session %q resolved (region %s)\n", a.Session.Name, a.Session.Region)
			return nil
		},
	}
}

// ---- schema ----

func schemaCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "schema",
		Short: "Print the embedded JSON Schema for the config",
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, err := cmd.OutOrStdout().Write(config.Schema())
			return err
		},
	}
}

// ---- version ----

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version and build information",
		RunE: func(cmd *cobra.Command, _ []string) error {
			info := struct {
				Version  string `json:"version"`
				Commit   string `json:"commit"`
				Date     string `json:"date"`
				Go       string `json:"go"`
				Platform string `json:"platform"`
			}{
				Version:  version,
				Commit:   commit,
				Date:     date,
				Go:       runtime.Version(),
				Platform: runtime.GOOS + "/" + runtime.GOARCH,
			}
			if out, _ := cmd.Flags().GetString("output"); out == "json" {
				return writeJSON(cmd, info)
			}
			fmt.Fprintf(cmd.OutOrStdout(),
				"aws-sso-profiles %s\n  commit:   %s\n  built:    %s\n  go:       %s\n  platform: %s\n",
				info.Version, info.Commit, info.Date, info.Go, info.Platform)
			return nil
		},
	}
}

// ---- cleanup ----

func cleanupCmd() *cobra.Command {
	var yes bool
	var session string
	c := &cobra.Command{
		Use:   "cleanup",
		Short: "Remove this prefix's managed block (or only one session's profiles)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			target := fmt.Sprintf("managed block for prefix %q", a.Prefix())
			if session != "" {
				target = fmt.Sprintf("profiles for session %q in prefix %q", session, a.Prefix())
			}
			if !yes {
				fmt.Fprintf(cmd.OutOrStdout(), "Remove %s from %s? [y/N]: ", target, a.AWSConfigPath)
				r := bufio.NewReader(cmd.InOrStdin())
				line, _ := r.ReadString('\n')
				if !strings.EqualFold(strings.TrimSpace(line), "y") {
					fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
					return nil
				}
			}
			var changed bool
			var backup string
			if session != "" {
				changed, backup, err = a.CleanupSession(session)
			} else {
				changed, backup, err = a.Cleanup()
			}
			if err != nil {
				return err
			}
			if changed {
				fmt.Fprintf(cmd.OutOrStdout(), "Removed. Backup: %s\n", backup)
			} else {
				fmt.Fprintln(cmd.OutOrStdout(), "Nothing to remove.")
			}
			return nil
		},
	}
	c.Flags().BoolVarP(&yes, "yes", "y", false, "skip confirmation")
	c.Flags().StringVar(&session, "session", "", "remove only profiles bound to this sso_session")
	return c
}

// ---- check ----

func checkCmd() *cobra.Command {
	return &cobra.Command{
		Use:       "check [analyze|auto|manual|duplicates]",
		Short:     "Analyze profiles in the AWS config (managed vs manual, duplicates)",
		ValidArgs: []string{"analyze", "auto", "manual", "duplicates"},
		Args:      cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			a, err := loadApp(cmd)
			if err != nil {
				return err
			}
			content := a.AWSContent()
			all := awsconfig.AllProfileNames(content)
			managed := awsconfig.ManagedProfileNames(content)

			sub := "analyze"
			if len(args) == 1 {
				sub = args[0]
			}
			w := cmd.OutOrStdout()
			switch sub {
			case "analyze":
				manual := 0
				for _, n := range all {
					if !managed[n] {
						manual++
					}
				}
				fmt.Fprintf(w, "Total: %d\n", len(all))
				fmt.Fprintf(w, "Auto (managed): %d\n", len(managed))
				fmt.Fprintf(w, "Manual: %d\n", manual)
			case "auto":
				for _, n := range all {
					if managed[n] {
						fmt.Fprintln(w, n)
					}
				}
			case "manual":
				for _, n := range all {
					if !managed[n] {
						fmt.Fprintln(w, n)
					}
				}
			case "duplicates":
				seen := map[string]int{}
				for _, n := range all {
					seen[n]++
				}
				dupes := 0
				for _, n := range all {
					if seen[n] > 1 {
						seen[n] = 0 // print each once
						fmt.Fprintf(w, "%s (×%d)\n", n, countOf(all, n))
						dupes++
					}
				}
				if dupes == 0 {
					fmt.Fprintln(w, "No duplicate profiles.")
				}
			default:
				return fmt.Errorf("unknown check subcommand %q", sub)
			}
			return nil
		},
	}
}

func countOf(names []string, target string) int {
	n := 0
	for _, s := range names {
		if s == target {
			n++
		}
	}
	return n
}

// ---- output ----

type planJSON struct {
	Added     int              `json:"added"`
	Removed   int              `json:"removed"`
	Changed   int              `json:"changed"`
	Unchanged int              `json:"unchanged"`
	Changes   []plan.Change    `json:"changes"`
	Drift     []plan.DriftItem `json:"drift,omitempty"`
}

func reportPlan(cmd *cobra.Command, pl *plan.Plan, out string) error {
	added, removed, changed, unchanged := pl.Counts()
	if out == "json" {
		return writeJSON(cmd, planJSON{added, removed, changed, unchanged, pl.Changes, pl.Drift})
	}
	w := cmd.OutOrStdout()
	fmt.Fprintf(w, "Plan: %d to add, %d to change, %d to remove (%d unchanged)\n", added, changed, removed, unchanged)
	for _, ch := range pl.Changes {
		switch ch.Kind {
		case plan.Added:
			fmt.Fprintf(w, "  + %s\n", ch.Name)
		case plan.Changed:
			fmt.Fprintf(w, "  ~ %s (%s)\n", ch.Name, ch.Detail)
		case plan.Removed:
			fmt.Fprintf(w, "  - %s\n", ch.Name)
		}
	}
	if pl.HasDrift() {
		fmt.Fprintf(w, "Drift (hand-edits in managed block):\n")
		for _, d := range pl.Drift {
			fmt.Fprintf(w, "  ! %s — %s\n", d.Name, d.Reason)
		}
	}
	return nil
}

func writeJSON(cmd *cobra.Command, v any) error {
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
