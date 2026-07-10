// Package ssoapi enumerates the accounts and permission-set roles reachable
// with an SSO bearer token, using only the read-only SSO Portal operations
// ListAccounts and ListAccountRoles.
//
// The request region is pinned to the [sso-session].sso_region passed in — it
// is never taken from the SDK's ambient region resolution chain, which would
// let list calls drift to the wrong Identity Center endpoint.
package ssoapi

import (
	"context"
	"fmt"
	"sort"

	"github.com/aws/aws-sdk-go-v2/aws/retry"
	"github.com/aws/aws-sdk-go-v2/service/sso"
	"golang.org/x/sync/errgroup"
)

// Account is one reachable AWS account.
type Account struct {
	ID   string `json:"account_id"`
	Name string `json:"account_name"`
}

// AccountRoles pairs an account with its reachable role names (sorted).
type AccountRoles struct {
	Account Account  `json:"account"`
	Roles   []string `json:"roles"`
}

// SSOLister is the minimal SSO Portal surface the tool depends on. *sso.Client
// satisfies it; tests inject a fake.
type SSOLister interface {
	ListAccounts(context.Context, *sso.ListAccountsInput, ...func(*sso.Options)) (*sso.ListAccountsOutput, error)
	ListAccountRoles(context.Context, *sso.ListAccountRolesInput, ...func(*sso.Options)) (*sso.ListAccountRolesOutput, error)
}

// NewClient builds an anonymous SSO client pinned to region, with adaptive
// retry to weather Portal throttling during the ListAccountRoles fan-out.
func NewClient(region string, maxAttempts int) *sso.Client {
	if maxAttempts < 1 {
		maxAttempts = 5
	}
	retryer := retry.NewAdaptiveMode(func(o *retry.AdaptiveModeOptions) {
		o.StandardOptions = append(o.StandardOptions, func(so *retry.StandardOptions) {
			so.MaxAttempts = maxAttempts
		})
	})
	return sso.New(sso.Options{Region: region, Retryer: retryer})
}

// FetchInventory lists all accounts, then their roles concurrently (bounded by
// parallel). Results are deterministic: accounts sorted by ID, roles by name.
func FetchInventory(ctx context.Context, client SSOLister, accessToken string, parallel int) ([]AccountRoles, error) {
	if parallel < 1 {
		parallel = 8
	}
	accounts, err := listAccounts(ctx, client, accessToken)
	if err != nil {
		return nil, err
	}
	sort.Slice(accounts, func(i, j int) bool { return accounts[i].ID < accounts[j].ID })

	results := make([]AccountRoles, len(accounts))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(parallel)
	for i, a := range accounts {
		i, a := i, a
		g.Go(func() error {
			roles, err := listRoles(gctx, client, accessToken, a.ID)
			if err != nil {
				return fmt.Errorf("list roles for account %s (%s): %w", a.ID, a.Name, err)
			}
			sort.Strings(roles)
			results[i] = AccountRoles{Account: a, Roles: roles}
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return results, nil
}

func listAccounts(ctx context.Context, client SSOLister, token string) ([]Account, error) {
	var out []Account
	p := sso.NewListAccountsPaginator(client, &sso.ListAccountsInput{AccessToken: &token})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list accounts: %w", err)
		}
		for _, a := range page.AccountList {
			out = append(out, Account{ID: deref(a.AccountId), Name: deref(a.AccountName)})
		}
	}
	return out, nil
}

func listRoles(ctx context.Context, client SSOLister, token, accountID string) ([]string, error) {
	var roles []string
	p := sso.NewListAccountRolesPaginator(client, &sso.ListAccountRolesInput{
		AccessToken: &token,
		AccountId:   &accountID,
	})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, r := range page.RoleList {
			roles = append(roles, deref(r.RoleName))
		}
	}
	return roles, nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
