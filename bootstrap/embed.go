// Package bootstrap embeds cluster-level setup (roles) that a DBA runs once before migrations.
package bootstrap

import _ "embed"

// RolesSQL creates the NOLOGIN group roles the migrations grant privileges to. Idempotent.
//
//go:embed roles.sql
var RolesSQL string
