/*
Package toml parses and writes TOML 1.0 documents.

parse turns a document into a tree of Value nodes rooted at a Table. Tables keep
their keys in document order, so encoding a parsed tree writes the keys back in
the order they appeared. Every node in a tree comes from one allocator; free the
whole tree with table_destroy.

Errors come back as an Error value plus a Location that holds the 1-based line
and column of the offending character.

Example:
	import "core:fmt"
	import "shared:toml"

	main :: proc() {
		doc, err, loc := toml.parse("title = \"TOML\"\n[owner]\nname = \"Tom\"\n")
		if err != nil {
			fmt.eprintfln("%d:%d: %v", loc.line, loc.column, err)
			return
		}
		defer toml.table_destroy(doc)

		name, _ := toml.get_string(doc, "owner", "name")
		fmt.println(name) // Tom
	}

A tree is safe to read from several threads at once. Mutating it, or destroying
it, needs exclusive access.
*/
package toml

import "base:runtime"
import "core:io"
import "core:math"

/*
Value is one TOML value. A nil Value never comes out of parse; the encoder
rejects it with `Encode_Error.Nil_Value`.

Strings, tables and arrays are owned by the tree that holds them. Free a
standalone Value with value_destroy.
*/
Value :: union {
	^Table,
	^Array,
	string,
	i64,
	f64,
	bool,
	Offset_Datetime,
	Local_Datetime,
	Date,
	Time,
}

/*
Table is a TOML table: a set of unique keys, each mapped to a Value.

`keys` lists the keys in insertion order and `values` maps each key to its
value. The strings in `keys` are the same allocations as the map keys. Read
both fields freely, but change a table only through table_set, so that the two
stay in sync.

Create one with table_make and free it, with everything it holds, using
table_destroy.
*/
Table :: struct {
	keys:      [dynamic]string,
	values:    map[string]Value,
	allocator: runtime.Allocator,
}

/*
Array is a TOML array. Arrays may mix value types, as TOML 1.0 allows.

Create one with array_make, add values with array_append and free it, with
everything it holds, using array_destroy.
*/
Array :: struct {
	items:     [dynamic]Value,
	allocator: runtime.Allocator,
}

// Date is a calendar date without a time or offset, such as `1979-05-27`.
Date :: struct {
	year:  int,
	month: int,
	day:   int,
}

/*
Time is a time of day without a date or offset, such as `07:32:00.999`.

`nanosecond` holds the fractional seconds. Digits beyond nanosecond precision
are truncated when parsing.
*/
Time :: struct {
	hour:       int,
	minute:     int,
	second:     int,
	nanosecond: int,
}

// Local_Datetime is a date and time without an offset, such as `1979-05-27T07:32:00`.
Local_Datetime :: struct {
	date: Date,
	time: Time,
}

/*
Offset_Datetime is a date and time at a fixed offset from UTC, such as
`1979-05-27T07:32:00-07:00`. `offset_minutes` is the offset east of UTC in
minutes, so `-07:00` is -420 and `Z` is 0.
*/
Offset_Datetime :: struct {
	date:           Date,
	time:           Time,
	offset_minutes: int,
}

// Parse_Error lists the ways a document can be malformed.
Parse_Error :: enum {
	None,
	// The document ended in the middle of a construct.
	Unexpected_Eof,
	// A character that can't start or continue the current construct.
	Unexpected_Character,
	// The document isn't valid UTF-8.
	Invalid_Utf8,
	// A control character other than tab appeared in a string or comment.
	Invalid_Control_Character,
	// A carriage return that isn't followed by a line feed.
	Bare_Carriage_Return,
	// A key was expected, for example at the start of a line or after a dot.
	Expected_Key,
	// A key wasn't followed by `=`.
	Expected_Equals,
	// An `=` or an array separator wasn't followed by a value.
	Expected_Value,
	// A key/value pair or table header was followed by more text on the same line.
	Expected_Newline,
	// An array element wasn't followed by `,` or `]`.
	Expected_Comma_Or_Bracket,
	// An inline table entry wasn't followed by `,` or `}`.
	Expected_Comma_Or_Brace,
	// A table header wasn't closed with `]` or `]]`.
	Unterminated_Table_Header,
	// An inline table ended with a comma before `}`.
	Trailing_Comma_In_Inline_Table,
	// A string ran into the end of the line or document.
	Unterminated_String,
	// A backslash sequence isn't one that TOML defines.
	Invalid_Escape,
	// A `\u` or `\U` escape isn't a Unicode scalar value.
	Invalid_Unicode_Escape,
	// A malformed integer, such as `012`, `1__0` or `+0x1`.
	Invalid_Integer,
	// An integer outside the signed 64-bit range.
	Integer_Overflow,
	// A malformed or out-of-range float, such as `1.`, `.5` or `1e`.
	Invalid_Float,
	// A malformed or out-of-range date, time or date-time.
	Invalid_Datetime,
	// A key that the current table already defines.
	Duplicate_Key,
	// A table header for a table that's already defined.
	Duplicate_Table,
	// A dotted key or table header goes through a value that isn't a table.
	Not_A_Table,
	// A dotted key or table header tries to extend an inline table.
	Inline_Table_Is_Immutable,
	// An array-of-tables header names an array defined with `[ ]` syntax.
	Static_Array_Is_Immutable,
	// Tables and arrays nest deeper than MAX_NESTING_DEPTH, counting header paths and dotted keys.
	Nesting_Too_Deep,
}

// Encode_Error lists the ways a tree can fail to encode.
Encode_Error :: enum {
	None,
	// The tree holds a nil Value, which TOML can't express.
	Nil_Value,
	// Tables or arrays nest deeper than MAX_NESTING_DEPTH, which usually means a cycle.
	Nesting_Too_Deep,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a specific variant such as
`toml.Parse_Error.Duplicate_Key`, or use a type switch.
*/
Error :: union #shared_nil {
	Parse_Error,
	Encode_Error,
	io.Error,
	runtime.Allocator_Error,
}

/*
Location points at a character in the source document.

`line` and `column` start at 1; `column` counts Unicode code points, not bytes.
`offset` is the 0-based byte offset.
*/
Location :: struct {
	offset: int,
	line:   int,
	column: int,
}

/*
MAX_NESTING_DEPTH bounds how deeply tables and arrays may nest below the root
table, which keeps the parser, the encoder and table_destroy off the edge of
the stack. Every part of a table header or dotted key counts as one level, as
does every array and inline table. parse rejects deeper documents, so any tree
it returns also encodes.
*/
MAX_NESTING_DEPTH :: 256

/*
table_make allocates an empty table.

Returns:
- t: a new table owned by the caller; free it with table_destroy. The table
  stores `allocator` and uses it for every later allocation.
- err: an allocator error.
*/
table_make :: proc(allocator := context.allocator) -> (t: ^Table, err: runtime.Allocator_Error) {
	t = new(Table, allocator) or_return
	t.allocator = allocator
	t.keys = make([dynamic]string, allocator)
	t.values = make(map[string]Value, allocator)
	return t, nil
}

/*
table_destroy frees `t`, every key and every value it holds, recursively.
Passing nil does nothing.
*/
table_destroy :: proc(t: ^Table) {
	if t == nil {
		return
	}
	allocator := t.allocator
	for key in t.keys {
		value_destroy(t.values[key], allocator)
		delete(key, allocator)
	}
	delete(t.keys)
	delete(t.values)
	free(t, allocator)
}

/*
table_set stores `value` under `key`, replacing and destroying any previous
value. A new key goes to the end of the key order; a replaced key keeps its
place.

Inputs:
- t: the table to change.
- key: copied with `t.allocator`, so the caller keeps ownership of it.
- value: moves into the table. Strings, tables and arrays inside it must come
  from `t.allocator`, because table_destroy frees them with it.

Returns an allocator error. On error `value` is still owned by the caller.
*/
table_set :: proc(t: ^Table, key: string, value: Value) -> Error {
	if old, found := t.values[key]; found {
		value_destroy(old, t.allocator)
		t.values[key] = value
		return nil
	}
	owned := clone_string(key, t.allocator) or_return
	if _, err := append(&t.keys, owned); err != nil {
		delete(owned, t.allocator)
		return err
	}
	_, slot, _, err := map_entry(&t.values, owned)
	if err != nil {
		pop(&t.keys)
		delete(owned, t.allocator)
		return err
	}
	slot^ = value
	return nil
}

// table_get returns the value stored under `key` and whether it exists. The value stays owned by `t`.
table_get :: proc(t: ^Table, key: string) -> (value: Value, found: bool) {
	if t == nil {
		return nil, false
	}
	return t.values[key]
}

/*
array_make allocates an empty array.

Returns:
- a: a new array owned by the caller; free it with array_destroy. The array
  stores `allocator` and uses it for every later allocation.
- err: an allocator error.
*/
array_make :: proc(allocator := context.allocator) -> (a: ^Array, err: runtime.Allocator_Error) {
	a = new(Array, allocator) or_return
	a.allocator = allocator
	a.items = make([dynamic]Value, allocator)
	return a, nil
}

// array_destroy frees `a` and every value it holds, recursively. Passing nil does nothing.
array_destroy :: proc(a: ^Array) {
	if a == nil {
		return
	}
	allocator := a.allocator
	for item in a.items {
		value_destroy(item, allocator)
	}
	delete(a.items)
	free(a, allocator)
}

/*
array_append adds `value` to the end of `a`. The value moves into the array,
so strings, tables and arrays inside it must come from `a.allocator`.

Returns an allocator error. On error `value` is still owned by the caller.
*/
array_append :: proc(a: ^Array, value: Value) -> Error {
	_, err := append(&a.items, value)
	return err
}

/*
value_destroy frees whatever `value` owns: the string bytes, or the table or
array and everything inside it. Scalars own nothing.

`allocator` must be the one that allocated a string value. Tables and arrays
free themselves with their stored allocator.
*/
value_destroy :: proc(value: Value, allocator := context.allocator) {
	#partial switch v in value {
	case ^Table:
		table_destroy(v)
	case ^Array:
		array_destroy(v)
	case string:
		delete(v, allocator)
	}
}

/*
get follows `path` through nested tables and returns the value at its end.

Example:
	port, found := toml.get(doc, "server", "port")

Returns the value, still owned by the tree, and false when any key along the
path is missing or names something that isn't a table.
*/
get :: proc(t: ^Table, path: ..string) -> (value: Value, found: bool) {
	if t == nil || len(path) == 0 {
		return nil, false
	}
	current := t
	for key, i in path {
		value = current.values[key] or_return
		if i == len(path) - 1 {
			return value, true
		}
		current = value.(^Table) or_return
	}
	return nil, false
}

// get_string returns the string at `path`, or false when it's missing or not a string. The string stays owned by the tree.
get_string :: proc(t: ^Table, path: ..string) -> (value: string, found: bool) {
	v := get(t, ..path) or_return
	return v.(string)
}

// get_int returns the integer at `path`, or false when it's missing or not an integer.
get_int :: proc(t: ^Table, path: ..string) -> (value: i64, found: bool) {
	v := get(t, ..path) or_return
	return v.(i64)
}

// get_float returns the float at `path`, or false when it's missing or not a float. Integers aren't converted.
get_float :: proc(t: ^Table, path: ..string) -> (value: f64, found: bool) {
	v := get(t, ..path) or_return
	return v.(f64)
}

// get_bool returns the boolean at `path`, or false when it's missing or not a boolean.
get_bool :: proc(t: ^Table, path: ..string) -> (value: bool, found: bool) {
	v := get(t, ..path) or_return
	return v.(bool)
}

// get_table returns the table at `path`, or false when it's missing or not a table. The table stays owned by the tree.
get_table :: proc(t: ^Table, path: ..string) -> (value: ^Table, found: bool) {
	v := get(t, ..path) or_return
	return v.(^Table)
}

// get_array returns the array at `path`, or false when it's missing or not an array. The array stays owned by the tree.
get_array :: proc(t: ^Table, path: ..string) -> (value: ^Array, found: bool) {
	v := get(t, ..path) or_return
	return v.(^Array)
}

/*
value_equal reports whether two values hold the same data.

Tables compare as sets of keys, ignoring key order. Floats compare by value,
except that NaN equals NaN, so a parsed tree equals its own round trip.
*/
value_equal :: proc(a, b: Value) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case ^Table:
		y := b.(^Table) or_return
		return table_equal(x, y)
	case ^Array:
		y := b.(^Array) or_return
		if x == nil || y == nil {
			return x == y
		}
		if len(x.items) != len(y.items) {
			return false
		}
		for item, i in x.items {
			if !value_equal(item, y.items[i]) {
				return false
			}
		}
		return true
	case f64:
		y := b.(f64) or_return
		if math.is_nan(x) && math.is_nan(y) {
			return true
		}
		return x == y
	case string:
		y := b.(string) or_return
		return x == y
	case i64:
		y := b.(i64) or_return
		return x == y
	case bool:
		y := b.(bool) or_return
		return x == y
	case Offset_Datetime:
		y := b.(Offset_Datetime) or_return
		return x == y
	case Local_Datetime:
		y := b.(Local_Datetime) or_return
		return x == y
	case Date:
		y := b.(Date) or_return
		return x == y
	case Time:
		y := b.(Time) or_return
		return x == y
	}
	return false
}

@(private)
table_equal :: proc(a, b: ^Table) -> bool {
	if a == nil || b == nil {
		return a == b
	}
	if len(a.values) != len(b.values) {
		return false
	}
	for key, value in a.values {
		other := b.values[key] or_return
		if !value_equal(value, other) {
			return false
		}
	}
	return true
}

@(private)
clone_string :: proc(s: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	if len(s) == 0 {
		return "", nil
	}
	bytes := make([]byte, len(s), allocator) or_return
	copy(bytes, s)
	return string(bytes), nil
}
