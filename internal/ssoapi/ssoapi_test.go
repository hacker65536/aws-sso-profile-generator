package ssoapi

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sso"
	ssotypes "github.com/aws/aws-sdk-go-v2/service/sso/types"
)

// fakeSSO returns 8 accounts (paginated 2 per page) and 2 roles per account.
type fakeSSO struct{ roleCalls atomic.Int32 }

func (f *fakeSSO) ListAccounts(_ context.Context, in *sso.ListAccountsInput, _ ...func(*sso.Options)) (*sso.ListAccountsOutput, error) {
	all := make([]ssotypes.AccountInfo, 0, 8)
	for i := 1; i <= 8; i++ {
		id := fmt.Sprintf("10000000000%d", i)
		name := fmt.Sprintf("acct-%d", i)
		all = append(all, ssotypes.AccountInfo{AccountId: aws.String(id), AccountName: aws.String(name)})
	}
	start := 0
	if in.NextToken != nil {
		_, _ = fmt.Sscanf(*in.NextToken, "%d", &start)
	}
	end := start + 2
	var next *string
	if end < len(all) {
		next = aws.String(fmt.Sprintf("%d", end))
	} else {
		end = len(all)
	}
	return &sso.ListAccountsOutput{AccountList: all[start:end], NextToken: next}, nil
}

func (f *fakeSSO) ListAccountRoles(_ context.Context, in *sso.ListAccountRolesInput, _ ...func(*sso.Options)) (*sso.ListAccountRolesOutput, error) {
	f.roleCalls.Add(1)
	// Return roles out of order to prove sorting.
	return &sso.ListAccountRolesOutput{RoleList: []ssotypes.RoleInfo{
		{RoleName: aws.String("AWSReadOnlyAccess"), AccountId: in.AccountId},
		{RoleName: aws.String("AWSAdministratorAccess"), AccountId: in.AccountId},
	}}, nil
}

func TestFetchInventory(t *testing.T) {
	f := &fakeSSO{}
	inv, err := FetchInventory(context.Background(), f, "tok", 4)
	if err != nil {
		t.Fatal(err)
	}
	if len(inv) != 8 {
		t.Fatalf("got %d accounts, want 8", len(inv))
	}
	if n := f.roleCalls.Load(); n != 8 {
		t.Errorf("ListAccountRoles called %d times, want 8", n)
	}
	// Accounts sorted by ID; roles sorted by name.
	for i, ar := range inv {
		wantID := fmt.Sprintf("10000000000%d", i+1)
		if ar.Account.ID != wantID {
			t.Errorf("account %d = %s, want %s (unsorted?)", i, ar.Account.ID, wantID)
		}
		if len(ar.Roles) != 2 || ar.Roles[0] != "AWSAdministratorAccess" || ar.Roles[1] != "AWSReadOnlyAccess" {
			t.Errorf("roles for %s not sorted: %v", ar.Account.ID, ar.Roles)
		}
	}
	total := 0
	for _, ar := range inv {
		total += len(ar.Roles)
	}
	if total != 16 { // 8 accounts × 2 roles — the E2E parity number
		t.Errorf("total profiles = %d, want 16", total)
	}
}
