package toml_tests

import toml ".."
import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"

/*
Failing_Allocator forwards to `backing` until `budget` allocations have
succeeded, then reports Out_Of_Memory for every further allocation. Frees
always go through, so a tracking allocator underneath sees every leak and
every double free.
*/
Failing_Allocator :: struct {
	backing: runtime.Allocator,
	budget:  int,
	failed:  bool,
}

failing_allocator_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	f := (^Failing_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.budget <= 0 {
			f.failed = true
			return nil, .Out_Of_Memory
		}
		f.budget -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

failing_allocator :: proc(f: ^Failing_Allocator) -> runtime.Allocator {
	return {procedure = failing_allocator_proc, data = f}
}

OOM_DOCUMENT :: `
title = "oom"
"quoted key" = 'literal'
a.b.c = """multi
line é"""
ints = [1, 0x2A, -3, 4.5e1, inf]
when = 1979-05-27T07:32:00Z
inline = { x = 1, y.z = "two", w = [ { v = 'three' } ] }
[server]
host = "localhost"
[[items]]
name = "first"
[items.meta]
k = '''raw
text'''
[[items]]
name = "second"
`

@(test)
test_parse_survives_every_allocation_failure :: proc(t: ^testing.T) {
	for budget in 0 ..< 10_000 {
		track: mem.Tracking_Allocator
		tracking := tracked(&track)
		track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		failing := Failing_Allocator {
			backing = tracking,
			budget  = budget,
		}
		doc, err, _ := toml.parse(OOM_DOCUMENT, failing_allocator(&failing))
		if !failing.failed {
			testing.expectf(t, err == nil, "budget %d: unexpected %v", budget, err)
			toml.table_destroy(doc)
			expect_no_leaks(t, &track)
			return
		}
		_, is_alloc := err.(runtime.Allocator_Error)
		testing.expectf(t, is_alloc, "budget %d: want an allocator error, got %v", budget, err)
		testing.expectf(t, doc == nil, "budget %d: a failed parse must not return a tree", budget)
		toml.table_destroy(doc)
		expect_no_leaks(t, &track)
	}
	testing.expect(t, false, "the document needs more allocations than the test allows")
}

@(test)
test_encode_survives_every_allocation_failure :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, OOM_DOCUMENT)
	defer toml.table_destroy(doc)
	for budget in 0 ..< 1_000 {
		failing := Failing_Allocator {
			backing = context.allocator,
			budget  = budget,
		}
		out, err := toml.encode(doc, failing_allocator(&failing))
		if !failing.failed {
			testing.expectf(t, err == nil, "budget %d: unexpected %v", budget, err)
			delete(out)
			return
		}
		testing.expectf(t, err != nil && out == "", "budget %d: want an error and no output, got %v", budget, err)
	}
	testing.expect(t, false, "encoding needs more allocations than the test allows")
}

// nest repeats `piece` n times, using the temporary allocator.
nest :: proc(piece: string, n: int) -> string {
	return strings.repeat(piece, n, context.temp_allocator)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

@(test)
test_depth_limit_counts_keys_and_headers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)
	defer free_all(context.temp_allocator)

	// Dotted keys and header paths build nested tables too, so they count toward the limit.
	expect_invalid(
		t,
		{
			{cat(nest("a.", 300), "a = 1"), .Nesting_Too_Deep},
			{cat("[", nest("a.", 300), "a]"), .Nesting_Too_Deep},
			{cat("[[", nest("a.", 300), "a]]"), .Nesting_Too_Deep},
			{cat("[", nest("a.", 199), "a]\n", nest("b.", 100), "b = 1"), .Nesting_Too_Deep},
			{cat("[", nest("a.", 199), "a]\nb = ", nest("[", 100), nest("]", 100)), .Nesting_Too_Deep},
			{cat("a = { ", nest("b.", 300), "c = 1 }"), .Nesting_Too_Deep},
			{cat("a = ", nest("[", 257), nest("]", 257)), .Nesting_Too_Deep},
			{cat(nest("a.", 257), "a = 1"), .Nesting_Too_Deep},
			{cat("[", nest("a.", 256), "a]"), .Nesting_Too_Deep},
			{cat("[", nest("a.", 255), "a]\nb = []"), .Nesting_Too_Deep},
		},
	)

	// Everything at exactly MAX_NESTING_DEPTH parses and encodes back to an equal tree.
	at_limit := []string {
		cat("a = ", nest("[", 256), nest("]", 256)),
		cat(nest("a.", 256), "a = 1"),
		cat("[", nest("a.", 254), "a]\nb = []"),
		cat("[", nest("a.", 255), "a]\nb = 1"),
		cat("[[", nest("a.", 255), "a]]\nb = 1"),
		cat("[", nest("a.", 199), "a]\n", nest("b.", 56), "b = 1"),
		cat("[", nest("a.", 199), "a]\nb = ", nest("[", 56), nest("]", 56)),
		cat("a = { ", nest("b.", 255), "c = 1 }"),
	}
	for src in at_limit {
		expect_round_trip(t, src)
	}
}

// chain builds `depth` tables, each the only key of the one above it.
chain :: proc(depth: int) -> ^toml.Table {
	root, _ := toml.table_make()
	current := root
	for _ in 0 ..< depth {
		child, _ := toml.table_make()
		toml.table_set(current, "k", child)
		current = child
	}
	toml.table_set(current, "leaf", i64(1))
	return root
}

@(test)
test_encode_depth_limit_matches_parse :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	ok_tree := chain(toml.MAX_NESTING_DEPTH)
	defer toml.table_destroy(ok_tree)
	out := encode_ok(t, ok_tree)
	defer delete(out)
	back := parse_ok(t, out)
	defer toml.table_destroy(back)
	testing.expect(t, toml.value_equal(ok_tree, back), "a tree at the limit must round trip")

	deep_tree := chain(toml.MAX_NESTING_DEPTH + 1)
	defer toml.table_destroy(deep_tree)
	deep_out, err := toml.encode(deep_tree)
	testing.expect_value(t, err, toml.Error(toml.Encode_Error.Nesting_Too_Deep))
	testing.expect_value(t, deep_out, "")
}

@(test)
test_encode_rejects_values_toml_cannot_express :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	Bad :: struct {
		value: toml.Value,
		err:   toml.Encode_Error,
	}
	ok_date := toml.Date{2024, 2, 29}
	ok_time := toml.Time{23, 59, 60, 999_999_999}
	bad := []Bad {
		{toml.Date{10_000, 1, 1}, .Invalid_Datetime},
		{toml.Date{-1, 1, 1}, .Invalid_Datetime},
		{toml.Date{2023, 2, 29}, .Invalid_Datetime},
		{toml.Date{2024, 13, 1}, .Invalid_Datetime},
		{toml.Date{2024, 1, 0}, .Invalid_Datetime},
		{toml.Time{24, 0, 0, 0}, .Invalid_Datetime},
		{toml.Time{0, 60, 0, 0}, .Invalid_Datetime},
		{toml.Time{0, 0, 61, 0}, .Invalid_Datetime},
		{toml.Time{0, 0, 0, 1_000_000_000}, .Invalid_Datetime},
		{toml.Time{0, 0, 0, -1}, .Invalid_Datetime},
		{toml.Local_Datetime{toml.Date{2024, 4, 31}, ok_time}, .Invalid_Datetime},
		{toml.Offset_Datetime{ok_date, ok_time, 24 * 60}, .Invalid_Datetime},
		{toml.Offset_Datetime{ok_date, ok_time, -24 * 60}, .Invalid_Datetime},
		{toml.Offset_Datetime{ok_date, toml.Time{-1, 0, 0, 0}, 0}, .Invalid_Datetime},
		{"\xff", .Invalid_Utf8},
		{"ok \xed\xa0\x80 surrogate", .Invalid_Utf8},
	}
	for c in bad {
		doc, _ := toml.table_make()
		value := c.value
		if s, is_string := value.(string); is_string {
			// The tree frees its strings, so give it its own copy.
			value = strings.clone(s)
		}
		toml.table_set(doc, "v", value)
		out, err := toml.encode(doc)
		testing.expectf(t, err == toml.Error(c.err), "%v: want %v, got %v (%q)", c.value, c.err, err, out)
		delete(out)
		toml.table_destroy(doc)
	}

	// Keys must be valid UTF-8 too.
	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)
	toml.table_set(doc, "\xc0\x80", true)
	out, err := toml.encode(doc)
	testing.expect_value(t, err, toml.Error(toml.Encode_Error.Invalid_Utf8))
	testing.expect_value(t, out, "")

	// The extremes of every range still encode and parse back.
	edge, _ := toml.table_make()
	defer toml.table_destroy(edge)
	toml.table_set(edge, "low", toml.Offset_Datetime{toml.Date{0, 1, 1}, toml.Time{0, 0, 0, 0}, -(23 * 60 + 59)})
	toml.table_set(edge, "high", toml.Offset_Datetime{toml.Date{9999, 12, 31}, ok_time, 23 * 60 + 59})
	toml.table_set(edge, "leap", ok_date)
	edge_out := encode_ok(t, edge)
	defer delete(edge_out)
	back := parse_ok(t, edge_out)
	defer toml.table_destroy(back)
	testing.expect(t, toml.value_equal(edge, back), "extreme date-times must round trip")
}
