package app

import (
	"slices"
	"testing"
)

func TestWithoutEnv(t *testing.T) {
	in := []string{"PATH=/bin", "AWS_PROFILE=work", "HOME=/home/x", "AWS_PROFILE=dup"}
	got := withoutEnv(in, "AWS_PROFILE")
	want := []string{"PATH=/bin", "HOME=/home/x"}
	if !slices.Equal(got, want) {
		t.Errorf("withoutEnv = %v, want %v", got, want)
	}
	// Original slice must be unmodified.
	if len(in) != 4 {
		t.Errorf("input mutated: %v", in)
	}
}
