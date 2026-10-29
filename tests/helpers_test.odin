// Package toml_tests holds the unit tests for toml. Run them with `odin test tests`.
package toml_tests

import toml ".."
import "base:runtime"
import "core:mem"
import "core:testing"

/*
tracked starts a tracking allocator that wraps the current allocator. Use it as

	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

so every test fails on a leak or a bad free, not only on wrong values.
*/
tracked :: proc(track: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

// expect_no_leaks fails the test for every allocation still alive and every bad free, then frees the tracker.
expect_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location, loc = loc)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location, loc = loc)
	}
	mem.tracking_allocator_destroy(track)
}

// parse_ok parses `src` and fails the test with the error and location when it doesn't parse.
parse_ok :: proc(t: ^testing.T, src: string, loc := #caller_location) -> ^toml.Table {
	doc, err, at := toml.parse(src)
	testing.expectf(t, err == nil, "unexpected %v at %d:%d in %q", err, at.line, at.column, src, loc = loc)
	return doc
}

Invalid_Case :: struct {
	src: string,
	err: toml.Parse_Error,
}

// expect_invalid parses every case and checks that each fails with the expected Parse_Error and no tree.
expect_invalid :: proc(t: ^testing.T, cases: []Invalid_Case, loc := #caller_location) {
	for c in cases {
		doc, err, at := toml.parse(c.src)
		got, is_parse_error := err.(toml.Parse_Error)
		testing.expectf(
			t,
			is_parse_error && got == c.err,
			"%q: want %v, got %v at %d:%d",
			c.src,
			c.err,
			err,
			at.line,
			at.column,
			loc = loc,
		)
		testing.expectf(t, doc == nil, "%q: a failed parse must not return a tree", c.src, loc = loc)
		toml.table_destroy(doc)
	}
}
