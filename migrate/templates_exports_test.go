package migrate_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Tests for 000014: the agent template catalog (AGT-11, D54) with its guard on agents and pools, and
// the export/import bundle changes (D49).

const (
	tplA = "tpl_01JD3Z5Y8K2M4N6P8Q0R2S4TE1"
	tplB = "tpl_01JD3Z5Y8K2M4N6P8Q0R2S4TE2"
)

var (
	digestA = "sha256:" + strings.Repeat("a", 64)
	digestB = "sha256:" + strings.Repeat("b", 64)
	digestC = "sha256:" + strings.Repeat("c", 64)
)

func TestAgentTemplates(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)

	run := func(setup, sql string, args ...any) (int64, error) {
		var n int64
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if setup != "" {
				if _, err := tx.Exec(ctx, setup); err != nil {
					return err
				}
			}
			tag, err := tx.Exec(ctx, sql, args...)
			n = tag.RowsAffected()
			return err
		})
		return n, err
	}
	teamAdmin := `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'; SET LOCAL afs.team_ids = '` + teamA + `'`
	serviceAdmin := `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC9'; SET LOCAL afs.service_admin = 'on'`

	const insertTpl = `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest)
		VALUES ($1, $2, $3, $4, $5)`

	t.Run("columns are checked", func(t *testing.T) {
		good := []any{tplA, "hermes-dev", "hermes", []string{digestA, digestB}, digestA}
		with := func(i int, v any) []any {
			a := append([]any(nil), good...)
			a[i] = v
			return a
		}
		for name, args := range map[string][]any{
			"id with another prefix":         with(0, "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TE1"),
			"name not kebab-case":            with(1, "Hermes_Dev"),
			"name too short":                 with(1, "a"),
			"harness not kebab-case":         with(2, "Hermes Harness"),
			"no allowed digests":             with(3, []string{}),
			"a tag instead of a digest":      with(3, []string{"latest"}),
			"digest with uppercase hex":      with(3, []string{"sha256:" + strings.Repeat("A", 64)}),
			"digest too short":               with(3, []string{"sha256:abc"}),
			"one bad digest among good":      with(3, []string{digestA, "sha256:zz"}),
			"current digest not in the list": with(4, digestC),
		} {
			if _, err := conn.Exec(ctx, insertTpl, args...); sqlState(err) != "23514" {
				t.Errorf("%s: want 23514, got %v", name, err)
			}
		}
		if _, err := conn.Exec(ctx, insertTpl, with(3, nil)...); sqlState(err) != "23502" && sqlState(err) != "23514" {
			t.Errorf("NULL allowed digests: want 23502 or 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `INSERT INTO afs.agent_templates (id, name, harness, default_resources, allowed_image_digests, current_image_digest)
			VALUES ($1, 'x-tpl', 'hermes', '[]', ARRAY[$2], $2)`, tplB, digestA); sqlState(err) != "23514" {
			t.Errorf("default_resources not an object: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, insertTpl, good...); err != nil {
			t.Fatalf("valid template: %v", err)
		}
		if _, err := conn.Exec(ctx, insertTpl, with(0, tplB)...); sqlState(err) != "23505" {
			t.Errorf("duplicate name: want 23505, got %v", err)
		}
		var enabled bool
		var version int64
		if err := conn.QueryRow(ctx, `SELECT enabled, version FROM afs.agent_templates WHERE id = $1`, tplA).Scan(&enabled, &version); err != nil || !enabled || version != 1 {
			t.Errorf("defaults: enabled=%v version=%d (%v)", enabled, version, err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET description = 'x' WHERE id = $1`, tplA); err != nil {
			t.Fatal(err)
		}
		if err := conn.QueryRow(ctx, `SELECT version FROM afs.agent_templates WHERE id = $1`, tplA).Scan(&version); err != nil || version != 2 {
			t.Errorf("version after update = %d (%v), want 2", version, err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET current_image_digest = $2 WHERE id = $1`, tplA, digestC); sqlState(err) != "23514" {
			t.Errorf("moving the current digest outside the list: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET allowed_image_digests = ARRAY[$2] WHERE id = $1`, tplA, digestB); sqlState(err) != "23514" {
			t.Errorf("removing the current digest from the list: want 23514, got %v", err)
		}
		var revs int
		if err := conn.QueryRow(ctx, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = 'agent_templates' AND resource_id = $1`, tplA).Scan(&revs); err != nil || revs != 2 {
			t.Errorf("revisions = %d (%v), want 2 (insert and one update)", revs, err)
		}
	})

	t.Run("only service admins write templates; everyone signed in reads them", func(t *testing.T) {
		if _, err := run(teamAdmin, insertTpl, tplB, "rogue-tpl", "hermes", []string{digestA}, digestA); sqlState(err) != "42501" {
			t.Errorf("team caller inserting: want 42501, got %v", err)
		}
		for _, sql := range []string{
			`UPDATE afs.agent_templates SET enabled = false WHERE id = $1`,
			`UPDATE afs.agent_templates SET allowed_image_digests = ARRAY['` + digestA + `','` + digestC + `'] WHERE id = $1`,
			`DELETE FROM afs.agent_templates WHERE id = $1`,
		} {
			if n, err := run(teamAdmin, sql, tplA); err != nil || n != 0 {
				t.Errorf("%s by a team caller: %d rows, %v; want 0 rows", sql, n, err)
			}
		}
		var n int
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, teamAdmin); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_templates`).Scan(&n)
		}); err != nil || n != 1 {
			t.Errorf("team caller reads %d templates, want 1 (%v)", n, err)
		}
		if _, err := run(serviceAdmin, insertTpl, tplB, "ops-tpl", "hermes", []string{digestA}, digestA); err != nil {
			t.Errorf("service admin inserting: %v", err)
		}
		if n, err := run(serviceAdmin, `UPDATE afs.agent_templates SET description = 'by admin' WHERE id = $1`, tplB); err != nil || n != 1 {
			t.Errorf("service admin updating: %d, %v", n, err)
		}
		// The reconciler and the read-only role read; only the reconciler-style service roles see all rows.
		for _, role := range []string{"afs_reconciler", "afs_readonly"} {
			if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE `+role); err != nil {
					return err
				}
				return tx.QueryRow(ctx, `SELECT count(*) FROM afs.agent_templates`).Scan(&n)
			}); err != nil || n != 2 {
				t.Errorf("%s reads %d templates, want 2 (%v)", role, n, err)
			}
			if _, err := run(`SET LOCAL ROLE `+role, `UPDATE afs.agent_templates SET enabled = false WHERE id = $1`, tplA); sqlState(err) != "42501" {
				t.Errorf("%s updating: want 42501, got %v", role, err)
			}
		}
		if _, err := run(`SET LOCAL ROLE afs_gateway`, `SELECT 1 FROM afs.agent_templates`); sqlState(err) != "42501" {
			t.Errorf("gateway reading templates: want 42501, got %v", err)
		}
	})

	t.Run("template changes are announced without a team", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `LISTEN afs_desired_state`); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_templates SET description = 'announce' WHERE id = $1`, tplB); err != nil {
			t.Fatal(err)
		}
		wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		n, err := conn.WaitForNotification(wctx)
		if err != nil {
			t.Fatal(err)
		}
		if want := "agent_templates::" + tplB; n.Payload != want {
			t.Errorf("payload %q, want %q", n.Payload, want)
		}
		if _, err := conn.Exec(ctx, `UNLISTEN afs_desired_state`); err != nil {
			t.Fatal(err)
		}
	})

	// Agents and pools.
	const swarm = "team_01JD3Z5Y8K2M4N6P8Q0R2S4TE9"
	if _, err := conn.Exec(ctx, `INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'anthropic', 'Claude Sonnet');
		INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+teamA+`', 'claude-sonnet');
		INSERT INTO afs.teams (id, slug, display_name, kind, cost_center, owner_email, max_budget_usd, expires_at, teardown_rule)
		  VALUES ('`+swarm+`', 'cve-swarm', 'CVE swarm', 'ephemeral', 'CC900', 'sec@example.com', 500, now() + interval '7 days', 'at_work_complete');
		INSERT INTO afs.budgets (id, team_id, period, amount_usd, on_exhaust) VALUES ('bud_01JD3Z5Y8K2M4N6P8Q0R2S4TE8', '`+swarm+`', 'lifetime', 300, 'block');
		INSERT INTO afs.team_models (team_id, model_id) VALUES ('`+swarm+`', 'claude-sonnet')`); err != nil {
		t.Fatal(err)
	}
	image := func(d string) string { return "ghcr.io/stainedhead/hermes-dev@" + d }
	agent := func(id, name string, tpl any, img string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.agents (id, team_id, name, template, image, model_id, template_id)
			VALUES ($1, $2, $3, 'hermes-dev', $4, 'claude-sonnet', $5)`, id, teamA, name, img, tpl)
		return err
	}
	pool := func(id, name string, tpl any, img string) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.agent_pools (id, team_id, name, template, image, model_id, template_id)
			VALUES ($1, $2, $3, 'hermes-dev', $4, 'claude-sonnet', $5)`, id, swarm, name, img, tpl)
		return err
	}
	const (
		agentOK  = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4TF1"
		agentOld = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4TF2"
		agentNew = "agt_01JD3Z5Y8K2M4N6P8Q0R2S4TF3"
		poolOK   = "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TF4"
		poolNew  = "pool_01JD3Z5Y8K2M4N6P8Q0R2S4TF5"
	)

	t.Run("agents and pools without a template are not guarded", func(t *testing.T) {
		if err := agent(agentOld, "legacy-bot", nil, "ghcr.io/x/omp@sha256:abc"); err != nil {
			t.Errorf("agent without template_id: %v", err)
		}
		if err := pool("pool_01JD3Z5Y8K2M4N6P8Q0R2S4TF6", "legacy-pool", nil, "ghcr.io/x/omp@sha256:abc"); err != nil {
			t.Errorf("pool without template_id: %v", err)
		}
	})

	t.Run("a new agent or pool needs an enabled template and an allowed digest", func(t *testing.T) {
		if err := agent(agentOK, "ok-bot", tplA, image(digestA)); err != nil {
			t.Fatalf("agent with an allowed digest: %v", err)
		}
		if err := pool(poolOK, "ok-pool", tplA, image(digestB)); err != nil {
			t.Fatalf("pool with an allowed digest: %v", err)
		}
		if err := agent(agentNew, "new-bot", tplA, image(digestC)); sqlState(err) != "23514" {
			t.Errorf("agent with a digest not on the list: want 23514, got %v", err)
		}
		if err := pool(poolNew, "new-pool", tplA, image(digestC)); sqlState(err) != "23514" {
			t.Errorf("pool with a digest not on the list: want 23514, got %v", err)
		}
		if err := agent(agentNew, "new-bot", tplA, "ghcr.io/x/hermes@sha256:abc"); sqlState(err) != "23514" {
			t.Errorf("agent with a malformed digest: want 23514, got %v", err)
		}
		if err := agent(agentNew, "new-bot", tplA, "ghcr.io/x/hermes:latest"); sqlState(err) != "23514" {
			t.Errorf("agent with a tag: want 23514 (image check), got %v", err)
		}
		if err := agent(agentNew, "new-bot", "tpl_01JD3Z5Y8K2M4N6P8Q0R2S4TEZ", image(digestA)); sqlState(err) != "23503" {
			t.Errorf("agent with an unknown template: want 23503, got %v", err)
		}
		if err := pool(poolNew, "new-pool", "tpl_01JD3Z5Y8K2M4N6P8Q0R2S4TEZ", image(digestA)); sqlState(err) != "23503" {
			t.Errorf("pool with an unknown template: want 23503, got %v", err)
		}
	})

	t.Run("a changed template or image is checked, an unrelated update is not", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET image = $2 WHERE id = $1`, agentOK, image(digestC)); sqlState(err) != "23514" {
			t.Errorf("agent moved to a digest not on the list: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agent_pools SET image = $2 WHERE id = $1`, poolOK, image(digestC)); sqlState(err) != "23514" {
			t.Errorf("pool moved to a digest not on the list: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET image = $2 WHERE id = $1`, agentOK, image(digestB)); err != nil {
			t.Errorf("agent moved to another allowed digest: %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET template_id = $2 WHERE id = $1`, agentOld, tplA); sqlState(err) != "23514" {
			t.Errorf("legacy agent adopting a template with a digest it does not allow: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET template_id = NULL WHERE id = $1`, agentOK); err != nil {
			t.Errorf("clearing template_id: %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET template_id = $2 WHERE id = $1`, agentOK, tplA); err != nil {
			t.Errorf("setting template_id back: %v", err)
		}
	})

	t.Run("disabling a template or removing a digest blocks new use and leaves existing rows alone", func(t *testing.T) {
		if _, err := run(serviceAdmin, `UPDATE afs.agent_templates SET allowed_image_digests = ARRAY['`+digestA+`'] WHERE id = $1`, tplA); err != nil {
			t.Fatalf("removing a digest in use by an agent and a pool: %v", err)
		}
		if _, err := run(serviceAdmin, `UPDATE afs.agent_templates SET enabled = false WHERE id = $1`, tplA); err != nil {
			t.Fatalf("disabling a template in use: %v", err)
		}
		// The agent (digestB, now removed) and the pool keep working: unrelated updates go through.
		if n, err := conn.Exec(ctx, `UPDATE afs.agents SET description = 'still here' WHERE id = $1`, agentOK); err != nil || n.RowsAffected() != 1 {
			t.Errorf("unrelated update of an existing agent: %v", err)
		}
		if n, err := conn.Exec(ctx, `UPDATE afs.agent_pools SET workers = 3 WHERE id = $1`, poolOK); err != nil || n.RowsAffected() != 1 {
			t.Errorf("unrelated update of an existing pool: %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET image = image WHERE id = $1`, agentOK); err != nil {
			t.Errorf("update naming image without changing it: %v", err)
		}
		if err := agent(agentNew, "new-bot", tplA, image(digestA)); sqlState(err) != "23514" {
			t.Errorf("new agent on a disabled template: want 23514, got %v", err)
		}
		if err := pool(poolNew, "new-pool", tplA, image(digestA)); sqlState(err) != "23514" {
			t.Errorf("new pool on a disabled template: want 23514, got %v", err)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET image = $2 WHERE id = $1`, agentOK, image(digestA)); sqlState(err) != "23514" {
			t.Errorf("moving an agent to another digest of a disabled template: want 23514, got %v", err)
		}
		// Re-enabling reopens it.
		if _, err := run(serviceAdmin, `UPDATE afs.agent_templates SET enabled = true WHERE id = $1`, tplA); err != nil {
			t.Fatal(err)
		}
		if err := agent(agentNew, "new-bot", tplA, image(digestA)); err != nil {
			t.Errorf("new agent after re-enabling: %v", err)
		}
	})

	t.Run("a template in use cannot be deleted", func(t *testing.T) {
		if _, err := run(serviceAdmin, `DELETE FROM afs.agent_templates WHERE id = $1`, tplA); sqlState(err) != "23503" {
			t.Errorf("deleting a template in use: want 23503, got %v", err)
		}
		if n, err := run(serviceAdmin, `DELETE FROM afs.agent_templates WHERE id = $1`, tplB); err != nil || n != 1 {
			t.Errorf("deleting an unused template: %d, %v", n, err)
		}
	})
}

func TestExportBundles(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	insert := func(id, direction, status string, s3, sha any, size any) error {
		_, err := conn.Exec(ctx, `INSERT INTO afs.export_bundles (id, direction, schema_version, s3_uri, sha256, status, size_bytes)
			VALUES ($1, $2, 1, $3, $4, $5, $6)`, id, direction, s3, sha, status, size)
		return err
	}
	sha := strings.Repeat("d", 64)
	const (
		exp1 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG1"
		exp2 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG2"
		exp3 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG3"
		exp4 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG4"
		exp5 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG5"
		exp6 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG6"
		exp7 = "exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG7"
	)

	t.Run("an import has no S3 object", func(t *testing.T) {
		if err := insert(exp1, "import", "succeeded", nil, sha, 1024); err != nil {
			t.Errorf("succeeded import without s3_uri: %v", err)
		}
	})
	t.Run("a pending export has neither location nor checksum yet", func(t *testing.T) {
		if err := insert(exp2, "export", "pending", nil, nil, nil); err != nil {
			t.Errorf("pending export: %v", err)
		}
		if err := insert(exp3, "export", "failed", nil, nil, nil); err != nil {
			t.Errorf("failed export: %v", err)
		}
	})
	t.Run("a succeeded export has an S3 location and a checksum", func(t *testing.T) {
		if err := insert(exp4, "export", "succeeded", nil, sha, 10); sqlState(err) != "23514" {
			t.Errorf("succeeded export without s3_uri: want 23514, got %v", err)
		}
		if err := insert(exp4, "export", "succeeded", "s3://bucket/key", nil, 10); sqlState(err) != "23514" {
			t.Errorf("succeeded export without sha256: want 23514, got %v", err)
		}
		if err := insert(exp4, "import", "succeeded", nil, nil, 10); sqlState(err) != "23514" {
			t.Errorf("succeeded import without sha256: want 23514, got %v", err)
		}
		if err := insert(exp4, "export", "succeeded", "s3://bucket/key", sha, 10); err != nil {
			t.Errorf("complete succeeded export: %v", err)
		}
	})
	t.Run("size and checksum are checked", func(t *testing.T) {
		if err := insert(exp5, "export", "pending", nil, nil, -1); sqlState(err) != "23514" {
			t.Errorf("negative size_bytes: want 23514, got %v", err)
		}
		if err := insert(exp5, "export", "pending", nil, "XYZ", nil); sqlState(err) != "23514" {
			t.Errorf("malformed sha256: want 23514, got %v", err)
		}
	})
	t.Run("the reconciler records the outcome and nothing else", func(t *testing.T) {
		upd := func(sql string, args ...any) error {
			return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_reconciler`); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, sql, args...)
				return err
			})
		}
		if err := upd(`UPDATE afs.export_bundles SET status = 'succeeded', s3_uri = 's3://bucket/k', sha256 = $2,
			download_url = 'https://bucket.s3.amazonaws.com/k?X-Amz-Signature=abc', download_expires_at = now() + interval '7 days',
			size_bytes = 2048, finished_at = now(), summary = '{"teams": 3}' WHERE id = $1`, exp2, sha); err != nil {
			t.Errorf("reconciler finishing an export: %v", err)
		}
		if err := upd(`UPDATE afs.export_bundles SET status = 'succeeded', s3_uri = NULL WHERE id = $1`, exp3); sqlState(err) != "23514" {
			t.Errorf("reconciler marking an export succeeded without s3_uri: want 23514, got %v", err)
		}
		if err := upd(`UPDATE afs.export_bundles SET direction = 'import' WHERE id = $1`, exp2); sqlState(err) != "42501" {
			t.Errorf("reconciler changing direction: want 42501, got %v", err)
		}
		if err := upd(`INSERT INTO afs.export_bundles (id, direction, schema_version) VALUES ($1, 'export', 1)`, exp6); sqlState(err) != "42501" {
			t.Errorf("reconciler inserting: want 42501, got %v", err)
		}
		if err := upd(`DELETE FROM afs.export_bundles WHERE id = $1`, exp2); sqlState(err) != "42501" {
			t.Errorf("reconciler deleting: want 42501, got %v", err)
		}
	})
	t.Run("the API creates exports and imports as afs_app", func(t *testing.T) {
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC9'; SET LOCAL afs.service_admin = 'on'`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.export_bundles (id, direction, schema_version, sha256, status, dry_run)
				VALUES ($1, 'import', 1, $2, 'succeeded', true)`, exp7, sha)
			return err
		}); err != nil {
			t.Errorf("service admin recording an import: %v", err)
		}
	})
	t.Run("team callers cannot see or write bundles", func(t *testing.T) {
		var n int
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC1'; SET LOCAL afs.team_ids = 'team_01JD3Z5Y8K2M4N6P8Q0R2S4TA1'`); err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM afs.export_bundles`).Scan(&n); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO afs.export_bundles (id, direction, schema_version) VALUES ('exp_01JD3Z5Y8K2M4N6P8Q0R2S4TG8', 'export', 1)`)
			return err
		})
		if n != 0 {
			t.Errorf("team caller saw %d bundles", n)
		}
		if sqlState(err) != "42501" {
			t.Errorf("team caller inserting a bundle: want 42501, got %v", err)
		}
	})
}

func TestResolveRepoOwners(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	if _, err := conn.Exec(ctx, `INSERT INTO afs.namespace_config_values (id, team_id, name, config_value) VALUES
		('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4TH1', $1, 'AFS_OWNED_REPOS', 'github.com/acme/payments-api, github.com/acme/*
		 ghe.example.com/pay/ledger'),
		('ncv_01JD3Z5Y8K2M4N6P8Q0R2S4TH2', $2, 'AFS_OWNED_REPOS', 'github.com/Acme/search github.com/acme/*')`, teamA, teamB); err != nil {
		t.Fatal(err)
	}
	resolve := func(host, repo string) []string {
		t.Helper()
		var ids []string
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_01JD3Z5Y8K2M4N6P8Q0R2S4TC5'; SET LOCAL afs.security_operator = 'on'`); err != nil {
				return err
			}
			rows, err := tx.Query(ctx, `SELECT afs.resolve_repo_owners($1, $2)`, host, repo)
			if err != nil {
				return err
			}
			ids, err = pgx.CollectRows(rows, pgx.RowTo[string])
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return ids
	}
	cases := []struct {
		name, host, repo string
		want             []string
	}{
		{"exact entry beats a wildcard", "github.com", "acme/payments-api", []string{teamA}},
		{"matching ignores case", "github.com", "ACME/search", []string{teamB}},
		{"two wildcards are ambiguous", "github.com", "acme/other", []string{teamA, teamB}},
		{"host must match", "ghe.example.com", "pay/ledger", []string{teamA}},
		{"no owner", "github.com", "elsewhere/x", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := resolve(c.host, c.repo)
			if strings.Join(got, ",") != strings.Join(c.want, ",") {
				t.Errorf("resolve(%s, %s) = %v, want %v", c.host, c.repo, got, c.want)
			}
		})
	}
	t.Run("deleted teams own nothing", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.teams SET state = 'deleted', deleted_at = now() WHERE id = $1`, teamB); err != nil {
			t.Fatal(err)
		}
		if got := resolve("github.com", "acme/other"); strings.Join(got, ",") != teamA {
			t.Errorf("got %v, want only %s", got, teamA)
		}
	})
	t.Run("only the API and reconciler may call it", func(t *testing.T) {
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SET LOCAL ROLE afs_gateway`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `SELECT afs.resolve_repo_owners('github.com', 'acme/x')`)
			return err
		})
		if sqlState(err) != "42501" {
			t.Errorf("gateway: want 42501, got %v", err)
		}
	})
}
