package migrate_test

import (
	"strings"
	"testing"

	"github.com/stainedhead/enterprise-agent-factory-service-db/migrate"
	"github.com/stainedhead/enterprise-agent-factory-service-db/migrations"
)

// 000021 (taken down together with the migrations above it): the down migration restores the 000020 collab_routes() columns and grants; up again adds the client ids.
func TestMigration000021(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	migs, err := migrate.Load(migrations.FS)
	if err != nil {
		t.Fatal(err)
	}
	cols := func() string {
		return scalar[string](t, conn, "", `SELECT array_to_string(p.proargnames, ' ') FROM pg_proc p WHERE p.pronamespace = 'afs'::regnamespace AND p.proname = 'collab_routes'`)
	}
	acl := func() bool {
		return scalar[bool](t, conn, "", `SELECT has_function_privilege('afs_edge', 'afs.collab_routes()', 'EXECUTE') AND NOT has_function_privilege('afs_app', 'afs.collab_routes()', 'EXECUTE')`)
	}
	if !strings.HasSuffix(cols(), "provider_client_id provider_cli_client_id") || !acl() {
		t.Fatalf("after up: %s", cols())
	}
	above := len(migs) - 20 // 000021 and every migration after it
	if n, err := migrate.Down(ctx, conn, migs, above); err != nil || n != above {
		t.Fatalf("down: n=%d err=%v", n, err)
	}
	if !strings.HasSuffix(cols(), "collab_client_secret_arn") || !acl() {
		t.Fatalf("after down: %s", cols())
	}
	if n, err := migrate.Up(ctx, conn, migs); err != nil || n != above {
		t.Fatalf("up again: n=%d err=%v", n, err)
	}
	if !strings.HasSuffix(cols(), "provider_cli_client_id") || !acl() {
		t.Fatalf("after up again: %s", cols())
	}
}
