// Package migrations embeds the numbered SQL migrations for the Agent Factory database.
//
// Files are named NNNNNN_name.up.sql and NNNNNN_name.down.sql. Production applies up migrations
// only; down migrations exist for local development and tests.
package migrations

import "embed"

// FS holds every migration file.
//
//go:embed *.sql
var FS embed.FS
