// Example build creates a document from code and encodes it. Run it with `odin run examples/build`.
package main

import toml "../.."
import "core:fmt"
import "core:strings"

main :: proc() {
	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)

	// Values move into the tree, so strings must come from the tree's allocator.
	toml.table_set(doc, "name", strings.clone("odin-toml"))
	toml.table_set(doc, "version", strings.clone("0.1.0"))

	deps, _ := toml.table_make()
	toml.table_set(deps, "odin", strings.clone("dev-2026-09"))
	toml.table_set(doc, "dependencies", deps)

	authors, _ := toml.array_make()
	for name in ([]string{"alexisbcz"}) {
		author, _ := toml.table_make()
		toml.table_set(author, "name", strings.clone(name))
		toml.table_set(author, "since", toml.Date{2026, 10, 29})
		toml.array_append(authors, author)
	}
	toml.table_set(doc, "authors", authors)

	out, err := toml.encode(doc)
	if err != nil {
		fmt.eprintln("encode failed:", err)
		return
	}
	defer delete(out)
	fmt.print(out)
}
