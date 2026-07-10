# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub Security Advisories](https://github.com/hacker65536/aws-sso-profiles/security/advisories/new)
rather than opening a public issue. We aim to acknowledge reports within a few
business days.

When reporting, please include:

- the version (`aws-sso-profiles version`) and OS,
- a description of the impact, and
- reproduction steps or a proof of concept if available.

## Scope and threat model

`aws-sso-profiles` is a local, single-user CLI. It:

- reads `~/.aws/config` and the SSO bearer token that `aws sso login` cached
  under `~/.aws/sso/cache` (**read-only**; it never writes or logs the token),
- calls only the read-only AWS SSO Portal operations `ListAccounts` and
  `ListAccountRoles`,
- writes generated profiles into a marker-delimited *managed block* of
  `~/.aws/config` (atomic write, timestamped backup + rotation), and
- optionally shells out to `aws sso login` (argv form — no shell interpolation).

Because it edits a credentials-adjacent file, the primary hardening goal is that
**no data flowing in from the SSO API or the policy YAML can inject arbitrary
content into `~/.aws/config`** (e.g. a `credential_process` line). Identity
fields (account id, role name) and the rendered profile name are validated
against strict character sets before rendering, and user-supplied settings
keys/values are rejected if they contain newlines or square brackets.

Out of scope: multi-user/path-traversal boundaries (all file paths are the
invoking user's own), and the security of the AWS SDK / credential minting,
which is delegated to the official `aws` CLI and AWS SDK for Go.

## Supported versions

Only the latest released version is supported. Please upgrade before reporting.
