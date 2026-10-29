package toml_tests

import toml ".."
import "base:runtime"
import "core:mem"
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
