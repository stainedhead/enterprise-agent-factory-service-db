package migrate_test

import (
	"testing"

	"github.com/jackc/pgx/v5"
)

// TestSchemaVersionFunction proves every service role can read the applied schema version through
// afs.schema_version() while the tracking table itself stays unreadable to them (X-DB-7).
func TestSchemaVersionFunction(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	var want int64
	if err := conn.QueryRow(ctx, `SELECT max(version) FROM public.afs_schema_migrations`).Scan(&want); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly"} {
		t.Run(role, func(t *testing.T) {
			var got int64
			err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE `+role); err != nil {
					return err
				}
				return tx.QueryRow(ctx, `SELECT afs.schema_version()`).Scan(&got)
			})
			if err != nil || got != want {
				t.Fatalf("schema_version() = %d, %v; want %d", got, err, want)
			}
			err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE `+role); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `SELECT 1 FROM public.afs_schema_migrations`)
				return err
			})
			if sqlState(err) != "42501" {
				t.Errorf("tracking table readable by %s: %v", role, err)
			}
		})
	}
}
