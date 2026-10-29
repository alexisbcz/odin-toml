# odin-toml

[![CI](https://github.com/alexisbcz/odin-toml/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-toml/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

A TOML 1.0 parser and encoder for Odin. It reads a document into a tree of values, reports malformed input with a line and column, writes trees back out, and never allocates behind your back.

## Features

- The whole TOML 1.0 grammar: bare, quoted and dotted keys, all four string kinds, decimal, hex, octal and binary integers, floats with `inf` and `nan`, booleans, offset and local date-times, local dates and local times, arrays, inline tables, tables and arrays of tables.
- Every rule about defining tables: duplicate keys, redefined tables, dotted keys that reach into header tables, and writes into inline tables or static arrays all fail with a specific error.
- Errors are values. `parse` returns a `Parse_Error` and a `Location` with a 1-based line and code-point column. It never panics.
- Tables keep their keys in document order, and the encoder writes a document that parses back to an equal tree.
- One allocator per tree, passed explicitly, and one call to free it. Tests run under a tracking allocator and fail on any leak.

## Install

The repository root is the package, so you can vendor it in two ways. Clone it into a directory named `toml`, because Odin takes the import name from the directory. Otherwise, write `import toml "libs/odin-toml"`.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-toml libs/toml
```

```odin
import "libs/toml"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-toml ~/odin-shared/toml
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:toml"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:toml"

CONFIG :: `
[server]
host = "0.0.0.0"
port = 8080
`

main :: proc() {
	doc, err, loc := toml.parse(CONFIG)
	if err != nil {
		fmt.eprintfln("config:%d:%d: %v", loc.line, loc.column, err)
		return
	}
	defer toml.table_destroy(doc)

	host, _ := toml.get_string(doc, "server", "host")
	port, _ := toml.get_int(doc, "server", "port")
	fmt.printfln("listening on %s:%d", host, port)

	out, encode_err := toml.encode(doc)
	if encode_err != nil {
		return
	}
	defer delete(out)
	fmt.print(out)
}
```

## Values

`toml.Value` is a union. Each TOML type maps to one variant:

| TOML | Odin variant | Notes |
| --- | --- | --- |
| Table, inline table | `^Table` | `keys` in document order, `values` map |
| Array | `^Array` | `items`, mixed types allowed |
| String | `string` | Escapes decoded, CRLF in multi-line strings becomes LF |
| Integer | `i64` | Out-of-range literals fail with `.Integer_Overflow` |
| Float | `f64` | `inf`, `-inf` and `nan` included |
| Boolean | `bool` | |
| Offset date-time | `Offset_Datetime` | `offset_minutes` east of UTC |
| Local date-time | `Local_Datetime` | |
| Local date | `Date` | |
| Local time | `Time` | Fractional seconds kept to the nanosecond |

Read values with a type switch, a type assertion, or the typed getters, which walk a key path and return `false` when a key is missing or holds another type:

```odin
started, _ := toml.get(doc, "server", "started")
if at, ok := started.(toml.Offset_Datetime); ok {
	fmt.println(at.date.year)
}
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `parse(data, allocator)` | Parse a document into a tree | Yes | `table_destroy` |
| `encode(t, allocator)` | Write a tree as a TOML string | Yes | `delete` |
| `write(w, t)` | Write a tree to an `io.Writer` | No | Not needed |
| `get(t, ..path)` | Look up a value along a key path | No | Not needed |
| `get_string`, `get_int`, `get_float`, `get_bool`, `get_table`, `get_array` | Typed lookups | No | Not needed |
| `table_make(allocator)` | Create an empty table | Yes | `table_destroy` |
| `table_set(t, key, value)` | Insert or replace a value, copying the key | Yes | Owned by `t` |
| `table_get(t, key)` | Look up one key | No | Not needed |
| `array_make(allocator)` | Create an empty array | Yes | `array_destroy` |
| `array_append(a, value)` | Append a value | Yes | Owned by `a` |
| `value_destroy(v, allocator)` | Free a value that isn't in a tree | No | Not needed |
| `value_equal(a, b)` | Compare two trees, ignoring key order | No | Not needed |
| `Error` | Union of `Parse_Error`, `Encode_Error`, `io.Error` and `runtime.Allocator_Error` | No | Not needed |

## Ownership

- `parse` copies every string it keeps, so you can free the input as soon as it returns.
- A table or array stores the allocator that created it. `table_destroy` frees the table and everything under it.
- `table_set` and `array_append` take ownership of the value. Strings, tables and arrays you add must come from the same allocator as the tree.
- To skip the free walk, parse into an arena and free the arena.

## Errors

```odin
_, err, loc := toml.parse("name = \"unterminated\nport = 80\n")
fmt.printfln("line %d, column %d: %v", loc.line, loc.column, err)
// line 1, column 8: Unterminated_String
```

Compare against a specific error with `err == toml.Error(toml.Parse_Error.Duplicate_Key)`, or use a type switch on `err`. The `Parse_Error` member names read as messages, so printing them works well in tools.

## Encoding

`encode` writes each table's plain key/value pairs first, then its subtables as `[header]` sections and its arrays of tables as `[[header]]` sections. The encoder writes arrays that mix tables with other values, and tables inside such arrays, inline. Output is canonical: comments, blank lines and the original number formatting aren't kept.

## Conformance

The tests follow the valid and invalid categories of [toml-test](https://github.com/toml-lang/toml-test), with more than 250 documents across more than 70 test procedures. Choices where TOML leaves room:

- Integers must fit in `i64`, and `parse` rejects floats that overflow `f64`.
- Seconds may be 60, to allow leap seconds. `parse` drops digits past nanosecond precision.
- `parse` skips a leading UTF-8 byte order mark.
- Tables and arrays may nest 256 levels below the root. Each part of a table header or dotted key counts as a level, as does each array and inline table, so `encode` accepts every tree that `parse` returns.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic   # parse, read, edit and encode a configuration
odin run examples/build   # build a document from code
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result.
- Fallible procedures return `(T, Error)`, and `parse` adds a `Location`. The library never panics on bad input.
- The parser is a single recursive-descent pass over the source bytes with no separate tokenizer.
- The package keeps no global mutable state. A tree is safe to read from several threads at once; changing it needs exclusive access.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
