// Command afs-migrate applies the Agent Factory database migrations.
//
//	afs-migrate [--database-url URL] [--lock-timeout 10s] up | down N | version | bootstrap-roles
//
// The URL defaults to AFS_DATABASE_URL. --lock-timeout bounds how long each migration waits for a
// table lock (0 disables it). On RDS, connect as a member of afs_owner.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/stainedhead/enterprise-agent-factory-service-db/bootstrap"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

func main() {
	url := flag.String("database-url", os.Getenv("AFS_DATABASE_URL"), "PostgreSQL connection URL")
	lockTimeout := flag.Duration("lock-timeout", migrate.DefaultLockTimeout, "lock_timeout of each migration transaction (0 disables it)")
	flag.Parse()
	if err := run(context.Background(), *url, *lockTimeout, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "afs-migrate:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, url string, lockTimeout time.Duration, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: afs-migrate [--database-url URL] [--lock-timeout 10s] up | down N | version | bootstrap-roles")
	}
	if lockTimeout < 0 {
		return fmt.Errorf("--lock-timeout must not be negative")
	}
	opt := migrate.WithLockTimeout(lockTimeout)
	if url == "" {
		return fmt.Errorf("set --database-url or AFS_DATABASE_URL")
	}
	conn, err := pgx.Connect(ctx, url)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()

	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		return err
	}
	switch args[0] {
	case "up":
		n, err := migrate.Up(ctx, conn, migs, opt)
		fmt.Printf("applied %d migration(s)\n", n)
		return err
	case "down":
		if len(args) != 2 {
			return fmt.Errorf("down needs a step count")
		}
		steps, err := strconv.Atoi(args[1])
		if err != nil || steps < 1 {
			return fmt.Errorf("invalid step count %q", args[1])
		}
		n, err := migrate.Down(ctx, conn, migs, steps, opt)
		fmt.Printf("reverted %d migration(s)\n", n)
		return err
	case "version":
		v, err := migrate.Version(ctx, conn)
		fmt.Println(v)
		return err
	case "bootstrap-roles":
		_, err := conn.Exec(ctx, bootstrap.RolesSQL)
		return err
	}
	return fmt.Errorf("unknown command %q", args[0])
}
