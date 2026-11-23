package migrate_test

// Migration 000022, edge functions and access counts (spec 261123-orchestration-and-model-access; -db PRD DB-US-60).

import (
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// DB-US-60.
func TestOrchestrationRoutes(t *testing.T) {
	conn := edgeWorld(t)
	const pub, priv = "collab.example.com", "internal.example.com"
	route := func(team, surface string) string {
		t.Helper()
		rows, err := edgeRows(t, conn, `SELECT effective, reasons, hostname, public_hostname, private_hostname, exposure, limit_exposure, supported
			FROM afs.orchestration_routes() WHERE team_id = $1 AND surface = $2`, team, surface)
		wantOK(t, err)
		if len(rows) != 1 {
			t.Fatalf("%s %s: %d rows", team, surface, len(rows))
		}
		return rows[0]
	}
	set := func(sql string, args ...any) { t.Helper(); mustExec(t, conn, sql, args...) }
	levelsOf := func(ui, api string) {
		set(`UPDATE afs.team_collaboration SET web_ui_exposure = $2, web_api_exposure = $3 WHERE team_id = $1`, teamA, ui, api)
	}
	limitOf := func(l string) { set(`UPDATE afs.teams SET max_collaboration_exposure = $2 WHERE id = $1`, teamA, l) }
	setting := func(key, value string) {
		set(`UPDATE afs.service_settings SET value = $2::jsonb WHERE key = $1`, key, value)
	}

	t.Run("two rows per team, one per surface, in a fixed order", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT team_id, surface FROM afs.orchestration_routes()`)
		wantOK(t, err)
		want := []string{teamA + "|web_api", teamA + "|web_ui", teamB + "|web_api", teamB + "|web_ui"}
		if strings.Join(rows, ",") != strings.Join(want, ",") {
			t.Errorf("rows %v", rows)
		}
	})
	t.Run("public level on a public team, with the public hostname", func(t *testing.T) {
		levelsOf("public", "off")
		if got := route(teamA, "web_ui"); got != "public|[]|payments."+pub+"|payments."+pub+"|NULL|public|public|true" {
			t.Errorf("web_ui %s", got)
		}
		if got := route(teamA, "web_api"); !strings.HasPrefix(got, "off|[]|NULL|") {
			t.Errorf("web_api %s", got)
		}
	})
	t.Run("private level needs the private base domain", func(t *testing.T) {
		levelsOf("private", "off")
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "off|[base_domain_unset]|NULL|") {
			t.Errorf("no private domain: %s", got)
		}
		setting("orchestration.private_base_domain", `"`+priv+`"`)
		if got := route(teamA, "web_ui"); got != "private|[]|payments."+priv+"|payments."+pub+"|payments."+priv+"|private|public|true" {
			t.Errorf("private: %s", got)
		}
	})
	t.Run("the team limit caps the level and says so", func(t *testing.T) {
		levelsOf("public", "off")
		mustExec(t, conn, `ALTER TABLE afs.team_collaboration DISABLE TRIGGER team_collaboration_b_exposure_check`)
		limitOf("private")
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "private|[team_limit]|payments."+priv+"|") {
			t.Errorf("limit private: %s", got)
		}
		limitOf("off")
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "off|[team_limit]|NULL|") {
			t.Errorf("limit off: %s", got)
		}
		mustExec(t, conn, `ALTER TABLE afs.team_collaboration ENABLE TRIGGER team_collaboration_b_exposure_check`)
		limitOf("public")
	})
	t.Run("service kill switches name their reason", func(t *testing.T) {
		levelsOf("public", "off")
		setting("orchestration.public_endpoints", `false`)
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "off|[service_switch_public]|NULL|") {
			t.Errorf("public off: %s", got)
		}
		levelsOf("private", "off")
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "private|[]|") {
			t.Errorf("private is unaffected by the public switch: %s", got)
		}
		setting("orchestration.private_endpoints", `false`)
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "off|[service_switch_private]|NULL|") {
			t.Errorf("private off: %s", got)
		}
		setting("orchestration.public_endpoints", `true`)
		setting("orchestration.private_endpoints", `true`)
	})
	t.Run("a base domain that is unset", func(t *testing.T) {
		levelsOf("public", "off")
		setting("orchestration.public_base_domain", `null`)
		got := route(teamA, "web_ui")
		if !strings.HasPrefix(got, "off|[base_domain_unset]|NULL|NULL|payments."+priv) {
			t.Errorf("public domain unset: %s", got)
		}
		setting("orchestration.public_base_domain", `"`+pub+`"`)
	})
	t.Run("the provider needs a collaboration client for the Web UI only", func(t *testing.T) {
		levelsOf("public", "public")
		set(`UPDATE afs.identity_providers SET collab_client_secret_arn = NULL, collab_client_id = NULL WHERE id = $1`, idpP1)
		if got := route(teamA, "web_ui"); !strings.HasPrefix(got, "off|[provider_without_collab_client]|NULL|") {
			t.Errorf("web_ui without client: %s", got)
		}
		if got := route(teamA, "web_api"); !strings.HasPrefix(got, "public|[]|payments."+pub) {
			t.Errorf("web_api needs no client: %s", got)
		}
		set(`UPDATE afs.identity_providers SET collab_client_id = 'collab-web', collab_client_secret_arn = 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/idp/collab-AbCdEf' WHERE id = $1`, idpP1)
	})
	t.Run("reasons accumulate in a fixed order", func(t *testing.T) {
		levelsOf("public", "off")
		setting("orchestration.public_endpoints", `false`)
		setting("orchestration.public_base_domain", `null`)
		set(`UPDATE afs.identity_providers SET collab_client_secret_arn = NULL, collab_client_id = NULL WHERE id = $1`, idpP1)
		got := route(teamA, "web_ui")
		if !strings.HasPrefix(got, "off|[service_switch_public base_domain_unset provider_without_collab_client]|NULL|") {
			t.Errorf("reasons %s", got)
		}
		setting("orchestration.public_endpoints", `true`)
		setting("orchestration.public_base_domain", `"`+pub+`"`)
		set(`UPDATE afs.identity_providers SET collab_client_id = 'collab-web', collab_client_secret_arn = 'arn:aws:secretsmanager:us-east-1:111122223333:secret:afs/idp/collab-AbCdEf' WHERE id = $1`, idpP1)
	})
	t.Run("readiness and the not-ready reason", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT ready, not_ready_reason, service_name, port, provider_id FROM afs.orchestration_routes() WHERE team_id = $1 AND surface = 'web_ui'`, teamA)
		wantOK(t, err)
		if rows[0] != "false|starting|paperclip|3100|"+idpP1 {
			t.Errorf("row %s", rows[0])
		}
		set(`UPDATE afs.teams SET state = 'suspended' WHERE id = $1`, teamA)
		rows, _ = edgeRows(t, conn, `SELECT not_ready_reason FROM afs.orchestration_routes() WHERE team_id = $1 AND surface = 'web_ui'`, teamA)
		if rows[0] != "team_suspended" {
			t.Errorf("suspended: %s", rows[0])
		}
		set(`UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamA)
	})
	t.Run("a deleted team has no routes", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT count(*) FROM afs.orchestration_routes() WHERE team_id = $1`, teamB)
		wantOK(t, err)
		if rows[0] != "2" {
			t.Fatalf("rows %v", rows)
		}
		set(`UPDATE afs.teams SET state = 'deleting' WHERE id = $1`, teamB)
		rows, _ = edgeRows(t, conn, `SELECT count(*) FROM afs.orchestration_routes() WHERE team_id = $1`, teamB)
		if rows[0] != "0" {
			t.Errorf("a deleting team has %s routes", rows[0])
		}
		set(`UPDATE afs.teams SET state = 'active' WHERE id = $1`, teamB)
	})
	t.Run("collab_routes is the public view of the same data", func(t *testing.T) {
		levelsOf("public", "off")
		rows, err := edgeRows(t, conn, `SELECT hostname, web_ui_effective, rest_api_effective, may_expose FROM afs.collab_routes() WHERE team_id = $1`, teamA)
		wantOK(t, err)
		if rows[0] != "payments."+pub+"|true|false|true" {
			t.Errorf("collab_routes %s", rows[0])
		}
		levelsOf("private", "off")
		rows, _ = edgeRows(t, conn, `SELECT web_ui_effective, web_ui_enabled FROM afs.collab_routes() WHERE team_id = $1`, teamA)
		if rows[0] != "false|true" {
			t.Errorf("a private level is not effective on the public view: %s", rows[0])
		}
	})
	t.Run("orchestration_settings returns exactly the four edge keys", func(t *testing.T) {
		rows, err := edgeRows(t, conn, `SELECT key FROM afs.orchestration_settings()`)
		wantOK(t, err)
		want := "orchestration.private_base_domain,orchestration.private_endpoints,orchestration.public_base_domain,orchestration.public_endpoints"
		if strings.Join(rows, ",") != want {
			t.Errorf("keys %v", rows)
		}
	})
	t.Run("a Buzz team reports both surfaces unsupported", func(t *testing.T) {
		mustExec(t, conn, `INSERT INTO afs.agent_templates (id, name, harness, allowed_image_digests, current_image_digest, capabilities) VALUES
			($1, 'orchestration-buzz', 'buzz', ARRAY['`+collabDigest+`'], '`+collabDigest+`', '{orchestration,tool:buzz}')`, tplOrchBuzz)
		wantOK(t, pgx.BeginFunc(t.Context(), conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(t.Context(), `UPDATE afs.agents SET template_id = $1 WHERE id = $2`, tplOrchBuzz, collB); err != nil {
				return err
			}
			_, err := tx.Exec(t.Context(), `UPDATE afs.team_collaboration SET web_ui_exposure = 'off', web_api_exposure = 'off', tool = 'buzz', registration_mode = 'managed' WHERE team_id = $1`, teamB)
			return err
		}))
		for _, s := range []string{"web_ui", "web_api"} {
			if got := route(teamB, s); !strings.HasPrefix(got, "off|[]|NULL|") || !strings.HasSuffix(got, "|false") {
				t.Errorf("%s: %s", s, got)
			}
		}
		rows, _ := edgeRows(t, conn, `SELECT service_name, port FROM afs.orchestration_routes() WHERE team_id = $1 AND surface = 'web_ui'`, teamB)
		if rows[0] != "buzz|3000" {
			t.Errorf("buzz endpoint %s", rows[0])
		}
	})
}

// DB-US-60: access counts say which endpoint was used.
func TestRecordAccessExposure(t *testing.T) {
	conn := edgeWorld(t)
	bucket := time.Now().UTC().Truncate(5 * time.Minute).Format(time.RFC3339)
	row := func(extra string) string {
		return `{"bucket_start": "` + bucket + `", "team_id": "` + teamA + `", "surface": "web_ui", "principal_kind": "user", "principal_id": "sub-1", "outcome": "allowed", "requests": 2` + extra + `}`
	}
	record := func(rows ...string) error {
		_, err := edgeRows(t, conn, `SELECT afs.record_collab_access($1::jsonb)`, "["+strings.Join(rows, ",")+"]")
		return err
	}
	t.Run("the exposure defaults to public", func(t *testing.T) {
		wantOK(t, record(row(``)))
		if got := count(t, conn, `SELECT sum(requests)::int FROM afs.collaboration_access WHERE team_id = $1 AND exposure = 'public'`, teamA); got != 2 {
			t.Errorf("public requests %d", got)
		}
	})
	t.Run("private is kept apart and adds up per exposure", func(t *testing.T) {
		wantOK(t, record(row(`, "exposure": "private"`), row(`, "exposure": "private"`), row(``)))
		if got := count(t, conn, `SELECT sum(requests)::int FROM afs.collaboration_access WHERE team_id = $1 AND exposure = 'private'`, teamA); got != 4 {
			t.Errorf("private requests %d", got)
		}
		if got := count(t, conn, `SELECT sum(requests)::int FROM afs.collaboration_access WHERE team_id = $1 AND exposure = 'public'`, teamA); got != 4 {
			t.Errorf("public requests %d", got)
		}
	})
	t.Run("an unknown exposure 23514, and web_api is stored as rest_api", func(t *testing.T) {
		wantState(t, record(row(`, "exposure": "internal"`)), "23514")
		wantOK(t, record(strings.Replace(row(``), `"web_ui"`, `"web_api"`, 1)))
		if got := count(t, conn, `SELECT count(*) FROM afs.collaboration_access WHERE team_id = $1 AND surface = 'rest_api'`, teamA); got != 1 {
			t.Errorf("rest_api rows %d", got)
		}
	})
}
