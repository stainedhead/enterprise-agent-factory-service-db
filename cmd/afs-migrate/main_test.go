package main

import (
	"strings"
	"testing"
	"time"
)

func TestRunRejectsBadArguments(t *testing.T) {
	cases := []struct {
		name    string
		url     string
		timeout time.Duration
		args    []string
		want    string
	}{
		{"no command", "postgres://x", time.Second, nil, "usage"},
		{"no url", "", time.Second, []string{"up"}, "AFS_DATABASE_URL"},
		{"negative lock timeout", "postgres://x", -time.Second, []string{"up"}, "lock-timeout"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := run(t.Context(), c.url, c.timeout, c.args)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want %q, got %v", c.want, err)
			}
		})
	}
}
