package migrate_test

// Proofs for the service access functions and policies of 000016 (DB-US-38 to DB-US-43), requested by
// -restapi as X-DB-1 to X-DB-6.

import (
	"context"
	"crypto/sha256"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

var imageA = "ghcr.io/x/omp@sha256:" + strings.Repeat("a", 64)

// in runs fn in a transaction after settings (SET LOCAL ROLE ... and friends), and commits.
func in(t *testing.T, conn *pgx.Conn, settings string, fn func(tx pgx.Tx) error) error {
	t.Helper()
	return pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
		if settings != "" {
			if _, err := tx.Exec(t.Context(), settings); err != nil {
				return err
			}
		}
		return fn(tx)
	})
}

// executableBy checks which service roles (and PUBLIC) may execute fn, and that it is a SECURITY
// DEFINER function with a fixed search_path.
func executableBy(t *testing.T, conn *pgx.Conn, fn string, allowed ...string) {
	t.Helper()
	var definer, pinned, public bool
	err := conn.QueryRow(t.Context(), `
		SELECT p.prosecdef,
		       coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=pg_catalog, afs%', false),
		       p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
		  FROM pg_proc p WHERE p.oid = $1::regprocedure`, fn).Scan(&definer, &pinned, &public)
	if err != nil {
		t.Fatalf("%s: %v", fn, err)
	}
	if !definer || !pinned {
		t.Errorf("%s: SECURITY DEFINER %v, search_path pinned %v", fn, definer, pinned)
	}
	if public {
		t.Errorf("%s: PUBLIC may execute it", fn)
	}
	for _, role := range []string{"afs_app", "afs_reconciler", "afs_gateway", "afs_billing", "afs_readonly", "afs_edge"} {
		var may bool
		if err := conn.QueryRow(t.Context(), `SELECT has_function_privilege($1, $2, 'EXECUTE')`, role, fn).Scan(&may); err != nil {
			t.Fatal(err)
		}
		want := false
		for _, a := range allowed {
			want = want || a == role
		}
		if may != want {
			t.Errorf("%s: %s may execute %v, want %v", fn, role, may, want)
		}
	}
}

// DB-US-38 (X-DB-1).
func TestAuthenticateAPIKey(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	hash := func(key string) []byte { h := sha256.Sum256([]byte(key)); return h[:] }
	const (
		keyA   = "key_01JD3Z5Y8K2M4N6P8Q0R2S4TC1"
		keySvc = "key_01JD3Z5Y8K2M4N6P8Q0R2S4TC2"
		keyOld = "key_01JD3Z5Y8K2M4N6P8Q0R2S4TC3"
		keyRev = "key_01JD3Z5Y8K2M4N6P8Q0R2S4TC4"
	)
	_, err := conn.Exec(ctx, `
		INSERT INTO afs.api_keys (id, team_id, name, role, key_prefix, key_sha256, expires_at) VALUES
		  ($1, $5, 'ci', 'team_admin', 'afsk_aa', $6, now() + interval '30 days'),
		  ($2, NULL, 'scanner', 'security_operator', 'afsk_sv', $7, now() + interval '30 days'),
		  ($3, $5, 'old', 'team_viewer', 'afsk_ol', $8, now() + interval '30 days'),
		  ($4, $5, 'gone', 'team_viewer', 'afsk_go', $9, now() + interval '30 days')`,
		keyA, keySvc, keyOld, keyRev, teamA, hash("afsk_a"), hash("afsk_svc"), hash("afsk_old"), hash("afsk_rev"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `UPDATE afs.api_keys SET expires_at = created_at + interval '1 microsecond' WHERE id = $1`, keyOld); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `UPDATE afs.api_keys SET revoked_at = now() WHERE id = $1`, keyRev); err != nil {
		t.Fatal(err)
	}

	type found struct {
		KeyID, Principal, Role, State string
		TeamID, TeamState             *string
		Roles                         []string
		ExpiresAt                     time.Time
		RevokedAt                     *time.Time
	}
	// The API calls it before it knows the caller's team: no afs.team_ids, no service admin.
	lookup := func(t *testing.T, key string) []found {
		t.Helper()
		var out []found
		err := in(t, conn, "SET LOCAL ROLE afs_app", func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT key_id, principal, role, state, team_id, team_state, roles, expires_at, revoked_at
				FROM afs.authenticate_api_key($1)`, hash(key))
			if err != nil {
				return err
			}
			out, err = pgx.CollectRows(rows, pgx.RowToStructByPos[found])
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	lastUsed := func(t *testing.T, id string) *time.Time {
		t.Helper()
		var at *time.Time
		if err := conn.QueryRow(ctx, `SELECT last_used_at FROM afs.api_keys WHERE id = $1`, id).Scan(&at); err != nil {
			t.Fatal(err)
		}
		return at
	}

	t.Run("team key found without team scope", func(t *testing.T) {
		got := lookup(t, "afsk_a")
		if len(got) != 1 {
			t.Fatalf("got %d rows", len(got))
		}
		k := got[0]
		if k.KeyID != keyA || k.TeamID == nil || *k.TeamID != teamA || k.Role != "team_admin" ||
			k.Principal != keyA || len(k.Roles) != 1 || k.Roles[0] != "team_admin" || k.State != "active" || k.TeamState == nil || *k.TeamState != "active" {
			t.Fatalf("got %+v", k)
		}
	})
	t.Run("last_used_at at most once a minute", func(t *testing.T) {
		first := lastUsed(t, keyA)
		if first == nil {
			t.Fatal("last_used_at not set by the lookup")
		}
		lookup(t, "afsk_a")
		if again := lastUsed(t, keyA); !again.Equal(*first) {
			t.Fatalf("last_used_at moved within a minute: %v -> %v", first, again)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.api_keys SET last_used_at = now() - interval '2 minutes' WHERE id = $1`, keyA); err != nil {
			t.Fatal(err)
		}
		stale := lastUsed(t, keyA)
		lookup(t, "afsk_a")
		if fresh := lastUsed(t, keyA); !fresh.After(*stale) {
			t.Fatalf("last_used_at not refreshed after a minute: %v -> %v", stale, fresh)
		}
	})
	t.Run("service key has no team", func(t *testing.T) {
		got := lookup(t, "afsk_svc")
		if len(got) != 1 || got[0].TeamID != nil || got[0].Role != "security_operator" || got[0].TeamState != nil {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("expired and revoked keys are reported, not used", func(t *testing.T) {
		for key, want := range map[string]string{"afsk_old": "expired", "afsk_rev": "revoked"} {
			got := lookup(t, key)
			if len(got) != 1 || got[0].State != want {
				t.Fatalf("%s: got %+v, want state %s", key, got, want)
			}
		}
		for _, id := range []string{keyOld, keyRev} {
			if at := lastUsed(t, id); at != nil {
				t.Errorf("%s: last_used_at set on a key that cannot be used", id)
			}
		}
	})
	t.Run("suspended team is reported", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, teamA); err != nil {
			t.Fatal(err)
		}
		defer func() { _, _ = conn.Exec(ctx, `UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamA) }()
		if got := lookup(t, "afsk_a"); len(got) != 1 || got[0].TeamState == nil || *got[0].TeamState != "suspended" {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("unknown key", func(t *testing.T) {
		if got := lookup(t, "afsk_nope"); len(got) != 0 {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("no hash or secret in the result", func(t *testing.T) {
		rows, err := conn.Query(ctx, `SELECT * FROM afs.authenticate_api_key($1)`, hash("afsk_a"))
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range rows.FieldDescriptions() {
			if strings.Contains(f.Name, "sha") || strings.Contains(f.Name, "hash") || f.DataTypeOID == 17 {
				t.Errorf("result column %s exposes the key hash", f.Name)
			}
		}
		rows.Close()
	})
	t.Run("only the API may call it", func(t *testing.T) {
		executableBy(t, conn, "afs.authenticate_api_key(bytea)", "afs_app")
		err := in(t, conn, "SET LOCAL ROLE afs_gateway", func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT * FROM afs.authenticate_api_key($1)`, hash("afsk_a"))
			return err
		})
		if sqlState(err) != "42501" {
			t.Fatalf("gateway: %v", err)
		}
	})
}

// DB-US-39 (X-DB-2).
func TestResolveWorkload(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	type workload struct {
		TeamID          string
		AgentID, PoolID *string
	}
	resolve := func(t *testing.T, role, ns, sa string) []workload {
		t.Helper()
		var out []workload
		err := in(t, conn, "SET LOCAL ROLE "+role, func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT team_id, agent_id, pool_id FROM afs.resolve_workload($1, $2)`, ns, sa)
			if err != nil {
				return err
			}
			out, err = pgx.CollectRows(rows, pgx.RowToStructByPos[workload])
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	t.Run("agent", func(t *testing.T) {
		got := resolve(t, "afs_app", "afs-t-search", "agent-indexer")
		if len(got) != 1 || got[0].TeamID != teamB || got[0].AgentID == nil || *got[0].AgentID != agentB || got[0].PoolID != nil {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("pool, for the gateway too", func(t *testing.T) {
		got := resolve(t, "afs_gateway", "afs-t-swarm-b", "pool-fixer")
		if len(got) != 1 || got[0].TeamID != swarmB || got[0].PoolID == nil || *got[0].PoolID != poolFixB || got[0].AgentID != nil {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("no match", func(t *testing.T) {
		for _, c := range [][2]string{
			{"afs-t-search", "agent-nope"},
			{"afs-t-payments", "agent-indexer"}, // another team's namespace
			{"afs-t-search", "indexer"},         // no kind prefix
			{"afs-t-search", "default"},
			{"afs-t-search", "pool-indexer"}, // an agent is not a pool
			{"kube-system", "agent-indexer"},
		} {
			if got := resolve(t, "afs_app", c[0], c[1]); len(got) != 0 {
				t.Errorf("%s/%s: got %+v", c[0], c[1], got)
			}
		}
	})
	t.Run("only active teams and live workloads", func(t *testing.T) {
		if _, err := conn.Exec(ctx, `UPDATE afs.agents SET state = 'deleted', deleted_at = now() WHERE id = $1`, agentB); err != nil {
			t.Fatal(err)
		}
		if got := resolve(t, "afs_app", "afs-t-search", "agent-indexer"); len(got) != 0 {
			t.Errorf("deleted agent: got %+v", got)
		}
		if _, err := conn.Exec(ctx, `UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, swarmB); err != nil {
			t.Fatal(err)
		}
		if got := resolve(t, "afs_app", "afs-t-swarm-b", "pool-fixer"); len(got) != 0 {
			t.Errorf("suspended team: got %+v", got)
		}
	})
	t.Run("only the API and gateway may call it", func(t *testing.T) {
		executableBy(t, conn, "afs.resolve_workload(text,text)", "afs_app", "afs_gateway")
	})
}

// DB-US-40 (X-DB-3).
func TestTeamDirectory(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	if _, err := conn.Exec(ctx, `INSERT INTO afs.teams (id, slug, display_name, cost_center, owner_email, state, deleted_at)
		VALUES ('team_01JD3Z5Y8K2M4N6P8Q0R2S4TC5', 'retired', 'Retired', 'CC1', 'r@example.com', 'deleted', now())`); err != nil {
		t.Fatal(err)
	}
	directory := func(t *testing.T, settings string) ([]string, []string, error) {
		t.Helper()
		var ids, cols []string
		err := in(t, conn, "SET LOCAL ROLE afs_app; SET LOCAL afs.actor = 'usr_x'; "+settings, func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT * FROM afs.team_directory()`)
			if err != nil {
				return err
			}
			defer rows.Close()
			for _, f := range rows.FieldDescriptions() {
				cols = append(cols, f.Name)
			}
			for rows.Next() {
				v, err := rows.Values()
				if err != nil {
					return err
				}
				ids = append(ids, v[0].(string)+"/"+v[1].(string))
			}
			return rows.Err()
		})
		return ids, cols, err
	}
	want := "team_01JD3Z5Y8K2M4N6P8Q0R2S4T6V/payments,team_01JD3Z5Y8K2M4N6P8Q0R2S4T6W/search," + swarmB + "/swarm-b"
	for name, settings := range map[string]string{
		"security operator": "SET LOCAL afs.security_operator = 'on'",
		"service admin":     "SET LOCAL afs.service_admin = 'on'",
	} {
		t.Run(name+" sees every team not deleted", func(t *testing.T) {
			ids, cols, err := directory(t, settings)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Join(cols, ",") != "id,slug,display_name" {
				t.Errorf("columns %v", cols)
			}
			if strings.Join(ids, ",") != want {
				t.Errorf("got %v", ids)
			}
		})
	}
	for name, settings := range map[string]string{
		"team member": "SET LOCAL afs.team_ids = '" + teamA + "'",
		"no role":     "",
	} {
		t.Run(name+" is refused", func(t *testing.T) {
			if _, _, err := directory(t, settings); sqlState(err) != "42501" {
				t.Fatalf("got %v", err)
			}
		})
	}
	t.Run("only the API may call it", func(t *testing.T) {
		executableBy(t, conn, "afs.team_directory()", "afs_app")
	})
}

const (
	swtCVE  = "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TC6"
	swtBare = "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TC7"
	woCVE   = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TC8"
	woBare  = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TC9"
	woNoTpl = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCA"
	woDone  = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCB"
	woBadM  = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCC"
	swtBadM = "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TCD"
	woRace  = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCE"
	woOff   = "wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCF"
	swtOff  = "swt_01JD3Z5Y8K2M4N6P8Q0R2S4TCG"
)

func seedWorkOrderTemplates(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	spec := `{
	  "costCenter": "CC900", "ownerEmail": "secops@example.com", "tags": {"purpose": "remediation"},
	  "stages": [{"name": "scan", "position": 1}, {"name": "fix", "position": 2, "description": "Patch"}],
	  "pools": [
	    {"name": "scanner", "stage": "scan", "template": "omp", "image": "` + imageA + `", "modelId": "claude-sonnet", "workers": 2},
	    {"name": "fixer", "stage": "fix", "template": "omp", "image": "` + imageA + `", "modelId": "claude-sonnet", "workers": 1,
	     "persona": "Fix it", "resources": {"cpu": "1", "memory": "2Gi"}, "scratchSizeGiB": 40, "sharedVolume": "efs"}
	  ],
	  "handoffs": [{"from": "scanner", "to": "fixer"}],
	  "configValues": [{"pool": "fixer", "name": "MODE", "value": "patch"}],
	  "secrets": [{"pool": "fixer", "name": "gh-token"}]
	}`
	bare := `{"pools": [{"name": "solo", "template": "omp", "image": "` + imageA + `", "modelId": "claude-sonnet"}]}`
	badModel := `{"costCenter": "CC900", "ownerEmail": "secops@example.com",
	  "pools": [{"name": "solo", "template": "omp", "image": "` + imageA + `", "modelId": "no-such-model"}]}`
	_, err := conn.Exec(t.Context(), `
INSERT INTO afs.models (id, provider, display_name) VALUES ('claude-sonnet', 'Anthropic', 'Claude Sonnet');
INSERT INTO afs.swarm_templates (id, name, kind, spec, budget_usd, ttl_hours, teardown_rule, enabled) VALUES
 ('`+swtCVE+`', 'cve-fix', 'cve_remediation', '`+spec+`', 300, 72, 'at_work_complete', true),
 ('`+swtBare+`', 'bare', 'general', '`+bare+`', 120, 24, 'at_cap_or_expiry', true),
 ('`+swtBadM+`', 'bad-model', 'general', '`+badModel+`', 50, 24, 'at_expiry', true),
 ('`+swtOff+`', 'switched-off', 'general', '`+bare+`', 50, 24, 'at_expiry', false);
INSERT INTO afs.work_orders (id, kind, external_ref, title, sla_due_at, template_id, budget_usd) VALUES
 ('`+woCVE+`', 'cve_remediation', 'CVE-2026-12345', 'Patch libfoo', now() + interval '5 days', '`+swtCVE+`', 250),
 ('`+woRace+`', 'cve_remediation', 'CVE-2026-12346', 'Patch libbar', now() + interval '5 days', '`+swtCVE+`', 250);
INSERT INTO afs.work_orders (id, kind, title, template_id) VALUES
 ('`+woBare+`', 'general', 'Tidy', '`+swtBare+`'),
 ('`+woBadM+`', 'general', 'Bad model', '`+swtBadM+`'),
 ('`+woOff+`', 'general', 'Off', '`+swtOff+`');
INSERT INTO afs.work_orders (id, kind, title) VALUES ('`+woNoTpl+`', 'general', 'No template');
INSERT INTO afs.work_orders (id, kind, title, template_id, status) VALUES ('`+woDone+`', 'general', 'Cancelled', '`+swtBare+`', 'cancelled');
`)
	if err != nil {
		t.Fatal(err)
	}
	seedOrchestrationRuntime(t, conn)
}

// DB-US-41 (X-DB-4).
func TestInstantiateWorkOrderTeam(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedTeams(t, conn)
	seedWorkOrderTemplates(t, conn)
	const reconciler = "SET LOCAL ROLE afs_reconciler; SET LOCAL afs.actor = 'system:afs-reconciler'"
	instantiate := func(t *testing.T, wo string) (string, error) {
		t.Helper()
		var id string
		err := in(t, conn, reconciler, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT afs.instantiate_work_order_team($1)`, wo).Scan(&id)
		})
		return id, err
	}
	count := func(t *testing.T, sql string, args ...any) int {
		t.Helper()
		var n int
		if err := conn.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}

	var team string
	t.Run("creates the team from the template", func(t *testing.T) {
		var err error
		team, err = instantiate(t, woCVE)
		if err != nil {
			t.Fatal(err)
		}
		var (
			slug, kind, state, rule, cc, owner, ns string
			ceiling                                float64
			ttl                                    time.Duration
			okID                                   bool
		)
		err = conn.QueryRow(ctx, `SELECT afs.ulid_ok(id, 'team'), slug, kind, state, teardown_rule, cost_center, owner_email,
			namespace, max_budget_usd::float8, expires_at - now() FROM afs.teams WHERE id = $1`, team).
			Scan(&okID, &slug, &kind, &state, &rule, &cc, &owner, &ns, &ceiling, &ttl)
		if err != nil {
			t.Fatal(err)
		}
		if !okID || !strings.HasPrefix(slug, "wo-") || kind != "ephemeral" || state != "active" || rule != "at_work_complete" ||
			cc != "CC900" || owner != "secops@example.com" || ns != "afs-t-"+slug || ceiling != 250 {
			t.Errorf("team %s %s %s %s %s %s %s %v", slug, kind, state, rule, cc, owner, ns, ceiling)
		}
		if ttl < 71*time.Hour || ttl > 72*time.Hour {
			t.Errorf("expires in %v, want the template's 72 hours", ttl)
		}
		if n := count(t, `SELECT count(*) FROM afs.budgets WHERE team_id = $1 AND period = 'lifetime' AND on_exhaust = 'block' AND amount_usd = 250`, team); n != 1 {
			t.Errorf("lifetime budget of the work order: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.team_models WHERE team_id = $1 AND model_id = 'claude-sonnet'`, team); n != 1 {
			t.Errorf("team models: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.team_tags WHERE team_id = $1 AND key = 'purpose' AND value = 'remediation'`, team); n != 1 {
			t.Errorf("team tags: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.swarm_stages WHERE team_id = $1 AND ((name = 'scan' AND position = 1) OR (name = 'fix' AND position = 2 AND description = 'Patch'))`, team); n != 2 {
			t.Errorf("stages: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.agent_pools p JOIN afs.swarm_stages s ON s.team_id = p.team_id AND s.id = p.stage_id
			WHERE p.team_id = $1 AND ((p.name = 'scanner' AND s.name = 'scan' AND p.workers = 2)
			  OR (p.name = 'fixer' AND s.name = 'fix' AND p.workers = 1 AND p.persona = 'Fix it' AND p.scratch_size_gib = 40
			      AND p.shared_volume = 'efs' AND p.resources = '{"cpu": "1", "memory": "2Gi"}' AND p.image = $2))
			  AND afs.ulid_ok(p.id, 'pool')`, team, imageA); n != 2 {
			t.Errorf("pools: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.pool_handoffs h JOIN afs.agent_pools f ON f.id = h.from_pool_id JOIN afs.agent_pools o ON o.id = h.to_pool_id
			WHERE h.team_id = $1 AND f.name = 'scanner' AND o.name = 'fixer'`, team); n != 1 {
			t.Errorf("handoffs: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.pool_config_values v JOIN afs.agent_pools p ON p.id = v.pool_id
			WHERE v.team_id = $1 AND p.name = 'fixer' AND v.name = 'MODE' AND v.source = 'literal' AND v.config_value = 'patch'`, team); n != 1 {
			t.Errorf("config values: %d", n)
		}
		if n := count(t, `SELECT count(*) FROM afs.secrets WHERE team_id = $1`, team); n != 0 {
			t.Errorf("secrets created without a Secrets Manager ARN: %d", n)
		}
	})
	t.Run("assigns the work order", func(t *testing.T) {
		if n := count(t, `SELECT count(*) FROM afs.work_orders WHERE id = $1 AND team_id = $2 AND status = 'assigned' AND assigned_at IS NOT NULL`, woCVE, team); n != 1 {
			t.Fatal("work order not assigned to the new team")
		}
	})
	t.Run("writes audit, outbox and revisions", func(t *testing.T) {
		if n := count(t, `SELECT count(*) FROM afs.audit_log WHERE action = 'InstantiateWorkOrderTeam' AND actor_type = 'system'
			AND actor_id = 'system:afs-reconciler' AND outcome = 'allowed' AND resource_kind = 'work_orders' AND resource_id = $1
			AND team_id = $2 AND after ->> 'teamId' = $2`, woCVE, team); n != 1 {
			t.Errorf("audit rows: %d", n)
		}
		for event, id := range map[string]string{"team.created": team, "work_order.assigned": woCVE} {
			if n := count(t, `SELECT count(*) FROM afs.outbox_events WHERE event_type = $1 AND aggregate_id = $2 AND team_id = $3`, event, id, team); n != 1 {
				t.Errorf("%s outbox rows: %d", event, n)
			}
		}
		for _, kind := range []string{"teams", "budgets", "team_models", "swarm_stages", "agent_pools", "pool_config_values", "work_orders"} {
			if n := count(t, `SELECT count(*) FROM afs.config_revisions WHERE resource_kind = $1 AND changed_by = 'system:afs-reconciler'
				AND (team_id = $2 OR resource_id = $3)`, kind, team, woCVE); n == 0 {
				t.Errorf("no %s revision", kind)
			}
		}
	})
	t.Run("a second call returns the same team", func(t *testing.T) {
		teams := count(t, `SELECT count(*) FROM afs.teams`)
		again, err := instantiate(t, woCVE)
		if err != nil || again != team {
			t.Fatalf("got %s, %v; want %s", again, err, team)
		}
		if n := count(t, `SELECT count(*) FROM afs.teams`); n != teams {
			t.Errorf("teams %d -> %d", teams, n)
		}
		if n := count(t, `SELECT count(*) FROM afs.outbox_events WHERE event_type = 'team.created' AND team_id = $1`, team); n != 1 {
			t.Errorf("team.created written %d times", n)
		}
	})
	t.Run("concurrent calls create one team", func(t *testing.T) {
		var wg sync.WaitGroup
		ids := make([]string, 2)
		errs := make([]error, 2)
		conns := make([]*pgx.Conn, 2)
		for i := range conns {
			c, err := pgx.ConnectConfig(ctx, conn.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			conns[i] = c
			defer func() { _ = c.Close(context.Background()) }()
		}
		for i, c := range conns {
			wg.Add(1)
			go func() {
				defer wg.Done()
				errs[i] = pgx.BeginFunc(ctx, c, func(tx pgx.Tx) error {
					if _, err := tx.Exec(ctx, reconciler); err != nil {
						return err
					}
					return tx.QueryRow(ctx, `SELECT afs.instantiate_work_order_team($1)`, woRace).Scan(&ids[i])
				})
			}()
		}
		wg.Wait()
		if errs[0] != nil || errs[1] != nil || ids[0] != ids[1] {
			t.Fatalf("ids %v errors %v", ids, errs)
		}
		if n := count(t, `SELECT count(*) FROM afs.work_orders WHERE id = $1 AND team_id = $2`, woRace, ids[0]); n != 1 {
			t.Fatal("work order not assigned")
		}
	})
	t.Run("budget from the template, owner from service settings", func(t *testing.T) {
		if _, err := instantiate(t, woBare); sqlState(err) != "55000" {
			t.Fatalf("no owner email or cost center anywhere: %v", err)
		}
		for _, bad := range []string{
			`('work_orders.cost_center', '901')`,
			`('work_orders.cost_center', '""')`,
			`('work_orders.owner_email', '"nobody"')`,
			`('work_orders.owner_email', '["secops@example.com"]')`,
		} {
			if _, err := conn.Exec(ctx, `INSERT INTO afs.service_settings (key, value) VALUES `+bad); sqlState(err) != "23514" {
				t.Errorf("setting %s: %v", bad, err)
			}
		}
		if _, err := conn.Exec(ctx, `INSERT INTO afs.service_settings (key, value) VALUES
			('work_orders.owner_email', '"secops@example.com"'), ('work_orders.cost_center', '"CC901"')`); err != nil {
			t.Fatal(err)
		}
		id, err := instantiate(t, woBare)
		if err != nil {
			t.Fatal(err)
		}
		if n := count(t, `SELECT count(*) FROM afs.teams t JOIN afs.budgets b ON b.team_id = t.id
			WHERE t.id = $1 AND t.cost_center = 'CC901' AND t.owner_email = 'secops@example.com' AND t.teardown_rule = 'at_cap_or_expiry'
			  AND b.amount_usd = 120 AND t.max_budget_usd = 120`, id); n != 1 {
			t.Error("template budget, teardown rule or settings fallback not used")
		}
		if n := count(t, `SELECT count(*) FROM afs.agent_pools WHERE team_id = $1 AND name = 'solo' AND stage_id IS NULL AND workers = 1`, id); n != 1 {
			t.Error("pool without a stage not created with defaults")
		}
	})
	t.Run("refused", func(t *testing.T) {
		for name, c := range map[string]struct{ wo, state string }{
			"unknown work order":  {"wo_01JD3Z5Y8K2M4N6P8Q0R2S4TCZ", "P0002"},
			"no template":         {woNoTpl, "55000"},
			"cancelled":           {woDone, "55000"},
			"template disabled":   {woOff, "55000"},
			"model not in models": {woBadM, "23503"},
		} {
			t.Run(name, func(t *testing.T) {
				teams := count(t, `SELECT count(*) FROM afs.teams`)
				if _, err := instantiate(t, c.wo); sqlState(err) != c.state {
					t.Fatalf("got %v, want %s", err, c.state)
				}
				if n := count(t, `SELECT count(*) FROM afs.teams`); n != teams {
					t.Errorf("a refused call left a team behind")
				}
			})
		}
	})
	t.Run("only the reconciler may call it", func(t *testing.T) {
		executableBy(t, conn, "afs.instantiate_work_order_team(text)", "afs_reconciler")
		err := in(t, conn, appAdmin, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `SELECT afs.instantiate_work_order_team($1)`, woBare)
			return err
		})
		if sqlState(err) != "42501" {
			t.Fatalf("afs_app: %v", err)
		}
	})
}

// DB-US-42 (X-DB-5).
func TestReconcilerMarksPoolsDeleted(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	const reconciler = "SET LOCAL ROLE afs_reconciler"
	err := in(t, conn, reconciler, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE afs.agent_pools SET state = 'deleted', deleted_at = now() WHERE id = $1`, poolFixB)
		if err == nil && tag.RowsAffected() != 1 {
			t.Errorf("updated %d rows", tag.RowsAffected())
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`UPDATE afs.agent_pools SET workers = 9 WHERE id = '` + poolScanB + `'`,
		`UPDATE afs.agent_pools SET image = image WHERE id = '` + poolScanB + `'`,
	} {
		err := in(t, conn, reconciler, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, stmt); return err })
		if sqlState(err) != "42501" {
			t.Errorf("%s: %v", stmt, err)
		}
	}
}

// DB-US-43 (X-DB-6).
func TestServiceAuditAndOutboxInserts(t *testing.T) {
	conn := migrated(t)
	ctx := t.Context()
	seedOtherTeams(t, conn)
	insert := func(t *testing.T, settings, sql string, args ...any) error {
		t.Helper()
		return in(t, conn, "SET LOCAL ROLE afs_app; "+settings, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
	}
	const audit = `INSERT INTO afs.audit_log (actor_type, actor_id, action, outcome, team_id) VALUES ('user', $1, 'ListTeams', 'denied', $2)`
	const teamUser = "SET LOCAL afs.actor = 'usr_a'; SET LOCAL afs.team_ids = '" + teamA + "'"
	t.Run("own denied request with no team", func(t *testing.T) {
		if err := insert(t, teamUser, audit, "usr_a", nil); err != nil {
			t.Fatal(err)
		}
		if err := insert(t, "SET LOCAL afs.actor = 'usr_new'", audit, "usr_new", nil); err != nil {
			t.Fatalf("caller with no team at all: %v", err)
		}
	})
	t.Run("own denied request on a team the caller does not see", func(t *testing.T) {
		if err := insert(t, teamUser, audit, "usr_a", teamB); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("another actor's row is refused", func(t *testing.T) {
		for _, team := range []any{nil, teamB} {
			if err := insert(t, teamUser, audit, "usr_other", team); sqlState(err) != "42501" {
				t.Errorf("team %v: %v", team, err)
			}
		}
	})
	t.Run("the rows stay invisible to the caller", func(t *testing.T) {
		if n := scalar[int](t, conn, appTeamA, `SELECT count(*) FROM afs.audit_log WHERE team_id IS DISTINCT FROM $1`, teamA); n != 0 {
			t.Fatalf("team A sees %d audit rows of others", n)
		}
	})
	const outbox = `INSERT INTO afs.outbox_events (event_type, aggregate_kind, aggregate_id, team_id, payload) VALUES ($1, $2, $3, $4, '{}')`
	const operator = "SET LOCAL afs.actor = 'usr_sec'; SET LOCAL afs.security_operator = 'on'"
	t.Run("security operator work order events on any team", func(t *testing.T) {
		for _, team := range []any{nil, teamB} {
			if err := insert(t, operator, outbox, "work_order.cancelled", "work_orders", workOrdB, team); err != nil {
				t.Errorf("team %v: %v", team, err)
			}
		}
		if err := insert(t, operator, audit, "usr_sec", teamB); err != nil {
			t.Errorf("operator audit: %v", err)
		}
	})
	t.Run("other events are refused", func(t *testing.T) {
		cases := []struct {
			settings, event, kind string
		}{
			{operator, "team.created", "teams"},
			{operator, "work_order.cancelled", "teams"},
			{teamUser, "work_order.cancelled", "work_orders"},
		}
		for _, c := range cases {
			if err := insert(t, c.settings, outbox, c.event, c.kind, workOrdB, teamB); sqlState(err) != "42501" {
				t.Errorf("%s %s: %v", c.event, c.kind, err)
			}
		}
	})
}
