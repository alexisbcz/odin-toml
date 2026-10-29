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
