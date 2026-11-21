package main

import (
	"context"
	neturl "net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
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

// freshDatabase creates an empty database and returns its URL. Skips without AFS_TEST_DATABASE_URL.
func freshDatabase(t *testing.T) string {
	t.Helper()
	url := os.Getenv("AFS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("AFS_TEST_DATABASE_URL not set")
	}
	ctx := t.Context()
	admin, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	const name = "afs_test_cmd_afs_migrate"
	ident := pgx.Identifier{name}.Sanitize()
	_, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+ident)
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+ident); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+ident)
		_ = admin.Close(context.Background())
	})
	u, err := neturl.Parse(url)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	return u.String()
}

func TestRunCommands(t *testing.T) {
	url := freshDatabase(t)
	ctx := t.Context()
	steps := []struct {
		args []string
		want string // substring of the error, "" for success
	}{
		{[]string{"bootstrap-roles"}, ""},
		{[]string{"up"}, ""},
		{[]string{"version"}, ""},
		{[]string{"down"}, "step count"},
		{[]string{"down", "zero"}, "invalid step count"},
		{[]string{"down", "0"}, "invalid step count"},
		{[]string{"down", "1"}, ""},
		{[]string{"sideways"}, "unknown command"},
	}
	for _, s := range steps {
		err := run(ctx, url, time.Second, s.args)
		switch {
		case s.want == "" && err != nil:
			t.Errorf("%v: %v", s.args, err)
		case s.want != "" && (err == nil || !strings.Contains(err.Error(), s.want)):
			t.Errorf("%v: want %q, got %v", s.args, s.want, err)
		}
	}
	conn, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	if v, err := migrate.Version(ctx, conn); err != nil || v != len(migs)-1 {
		t.Errorf("version after up and down 1 = %d (%v), want %d", v, err, len(migs)-1)
	}
	if err := run(ctx, "postgres://nobody@127.0.0.1:1/none?connect_timeout=1", time.Second, []string{"version"}); err == nil {
		t.Error("an unreachable database succeeded")
	}
}
