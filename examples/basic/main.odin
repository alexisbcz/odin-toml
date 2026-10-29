// Example basic parses a configuration, reads typed values, edits one and writes the document back. Run it with `odin run examples/basic`.
package main

import toml "../.."
import "core:fmt"
import "core:os"

CONFIG :: `
title = "Example service"

[server]
host = "0.0.0.0"
port = 8080
started = 2026-10-29T09:00:00Z

[[users]]
name = "ada"
roles = ["admin", "dev"]

[[users]]
name = "linus"
roles = ["dev"]
`

main :: proc() {
	doc, err, loc := toml.parse(CONFIG)
	if err != nil {
		fmt.eprintfln("config:%d:%d: %v", loc.line, loc.column, err)
		os.exit(1)
	}
	defer toml.table_destroy(doc)

	host, _ := toml.get_string(doc, "server", "host")
	port, _ := toml.get_int(doc, "server", "port")
	fmt.printfln("listening on %s:%d", host, port)

	started, _ := toml.get(doc, "server", "started")
	if at, ok := started.(toml.Offset_Datetime); ok {
		fmt.printfln("started on %d-%02d-%02d", at.date.year, at.date.month, at.date.day)
	}

	if users, ok := toml.get_array(doc, "users"); ok {
		for item in users.items {
			user := item.(^toml.Table) or_continue
			name, _ := toml.get_string(user, "name")
			roles, _ := toml.get_array(user, "roles")
			fmt.printfln("user %s has %d roles", name, len(roles.items))
		}
	}

	// Change a value in place, then write the whole document back out.
	if server, ok := toml.get_table(doc, "server"); ok {
		if set_err := toml.table_set(server, "port", i64(9090)); set_err != nil {
			fmt.eprintln("table_set failed:", set_err)
			os.exit(1)
		}
	}
	out, encode_err := toml.encode(doc)
	if encode_err != nil {
		fmt.eprintln("encode failed:", encode_err)
		os.exit(1)
	}
	defer delete(out)
	fmt.print("\n", out, sep = "")

	// Malformed input reports what went wrong and where.
	_, bad_err, bad_loc := toml.parse("name = \"unterminated\nport = 80\n")
	fmt.printfln("\nline %d, column %d: %v", bad_loc.line, bad_loc.column, bad_err)
}
