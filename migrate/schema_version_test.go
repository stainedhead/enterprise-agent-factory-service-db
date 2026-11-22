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
	for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly", "afs_edge"} {
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

// TestIdentityProviderCLIClientID proves the CLI's public client id is stored separately from the
// console's and is length-checked (D48).
func TestIdentityProviderCLIClientID(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	insert := func(id, cli string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.identity_providers (id, name, kind, issuer_url, client_id, cli_client_id)
			VALUES ($1, $1, 'okta', 'https://' || lower($1) || '.example.com', 'console-client', nullif($2, '-'))`, id, cli)
		return err
	}
	if err := insert("idp_01JD3Z5Y8K2M4N6P8Q0R2S4TJ1", "afs-cli"); err != nil {
		t.Errorf("provider with a CLI client id: %v", err)
	}
	if err := insert("idp_01JD3Z5Y8K2M4N6P8Q0R2S4TJ2", "-"); err != nil {
		t.Errorf("provider without a CLI client id: %v", err)
	}
	if err := insert("idp_01JD3Z5Y8K2M4N6P8Q0R2S4TJ3", ""); sqlState(err) != "23514" {
		t.Errorf("empty CLI client id: want 23514, got %v", err)
	}
}
