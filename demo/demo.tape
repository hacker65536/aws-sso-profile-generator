# aws-sso-profiles — terminal demo (recorded with charmbracelet/vhs)
#
# Regenerate with:  make demo   (see demo/record.sh)
#
# This tape assumes the driver (demo/record.sh) exported:
#   PATH               -> a freshly built aws-sso-profiles binary
#   WORK               -> a scratch dir seeded with the demo fixtures
#   AWS_CONFIG_FILE    -> $WORK/aws_config
#   ASP_FAKE_INVENTORY -> $WORK/inv.json   (fake SSO inventory; no real AWS/login)

Output demo/aws-sso-profiles.gif

Require aws-sso-profiles

Set Shell "bash"
Set FontSize 18
Set Width 1120
Set Height 780
Set Padding 24
Set Theme "Dracula"
Set WindowBar Colorful
Set TypingSpeed 50ms

# --- hidden preamble: clean prompt + move into the scratch workspace ----------
Hide
Type `export PS1="aws-sso-demo $ "` Enter
Type `export PROMPT_COMMAND=` Enter
Type `cd "$WORK"` Enter
Type "clear" Enter
Show

# 1) What can it do? --------------------------------------------------------
Type "aws-sso-profiles --help" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 2) The single source of truth: a declarative config -----------------------
Type "cat .aws-sso-profiles.yaml" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 3) Validate the config (schema + semantics + org cross-check) -------------
Type "aws-sso-profiles validate" Enter
Sleep 2s

# 4) Plan: what would change? (exit 2 = diff present) -----------------------
Type "aws-sso-profiles plan" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 5) Apply: write only the managed block, after a backup --------------------
Type "aws-sso-profiles apply" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 6) Plan again -> no diff. apply is idempotent -----------------------------
Type "aws-sso-profiles plan" Enter
Sleep 3s

# 7) The generated profiles live next to your hand-written ones -------------
Type "grep '^\[profile' aws_config" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 8) drift: someone hand-edits a managed profile in ~/.aws/config -----------
Hide
Type `perl -0pi -e 's/(\[profile awssso-prod-100000000001:AWSReadOnlyAccess\]\n)/$1role_arn = arn:aws:iam::100000000001:role\/hand-added\n/' aws_config` Enter
Type "clear" Enter
Show
Type "# a teammate hand-edited a managed profile..." Enter
Type "grep -n role_arn aws_config" Enter
Sleep 2s

# 9) plan detects the drift (exit 2) ----------------------------------------
Type "aws-sso-profiles plan" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 10) apply re-canonicalizes: the hand-edit is healed -----------------------
Type "aws-sso-profiles apply" Enter
Sleep 3s
Hide
Type "clear" Enter
Show

# 11) check: managed vs manual at a glance ----------------------------------
Type "aws-sso-profiles check analyze" Enter
Sleep 3s

# 12) cleanup removes the managed block; hand-written profiles stay ---------
Type "aws-sso-profiles cleanup --yes" Enter
Sleep 2s
Type "grep '^\[profile' aws_config" Enter
Sleep 3s

Sleep 2s
