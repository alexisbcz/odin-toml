package toml_tests

import toml ".."
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

// encode_ok encodes `doc` and fails the test on error. The caller deletes the result.
encode_ok :: proc(t: ^testing.T, doc: ^toml.Table, loc := #caller_location) -> string {
	out, err := toml.encode(doc)
	testing.expectf(t, err == nil, "encode failed: %v", err, loc = loc)
	return out
}

// expect_round_trip parses `src`, encodes it, parses the output and checks both trees match.
expect_round_trip :: proc(t: ^testing.T, src: string, loc := #caller_location) {
	first := parse_ok(t, src, loc)
	defer toml.table_destroy(first)
	out := encode_ok(t, first, loc)
	defer delete(out)
	second, err, at := toml.parse(out)
	defer toml.table_destroy(second)
	testing.expectf(t, err == nil, "re-parse failed with %v at %d:%d:\n%s", err, at.line, at.column, out, loc = loc)
	testing.expectf(t, toml.value_equal(first, second), "round trip changed the document:\n%s", out, loc = loc)
}

@(test)
test_encode_scalars :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "s = 'hi'\ni = -42\nf = 1.5\nb = true\nhex = 0xff\n")
	defer toml.table_destroy(doc)
	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, "s = \"hi\"\ni = -42\nf = 1.5\nb = true\nhex = 255\n")
}

@(test)
test_encode_floats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)
	toml.table_set(doc, "whole", 1.0)
	toml.table_set(doc, "neg_zero", math.copy_sign_f64(0, -1))
	toml.table_set(doc, "big", 1e21)
	toml.table_set(doc, "tiny", 1e-7)
	toml.table_set(doc, "pinf", math.inf_f64(1))
	toml.table_set(doc, "ninf", math.inf_f64(-1))
	toml.table_set(doc, "nan", math.nan_f64())
	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, "whole = 1.0\nneg_zero = -0.0\nbig = 1e+21\ntiny = 1e-07\npinf = inf\nninf = -inf\nnan = nan\n")
}

@(test)
test_encode_escapes_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)
	toml.table_set(doc, "s", strings.clone("quote\" back\\ tab\t nl\n cr\r bell\x07 del\x7f é"))
	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, `s = "quote\" back\\ tab\t nl\n cr\r bell\u0007 del\u007F é"` + "\n")
}

@(test)
test_encode_quotes_keys_only_when_needed :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "bare-key_1 = 1\n\"with space\" = 2\n\"\" = 3\n\"dot.ted\" = 4\n['tab\tle']\nx = 5\n")
	defer toml.table_destroy(doc)
	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, "bare-key_1 = 1\n\"with space\" = 2\n\"\" = 3\n\"dot.ted\" = 4\n\n[\"tab\\tle\"]\nx = 5\n")
}

@(test)
test_encode_sections_and_arrays_of_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
title = "x"
[a.b]
c = 1
[[fruit]]
name = "apple"
[fruit.color]
hex = "f00"
[[fruit]]
name = "pear"
[empty]
`)
	defer toml.table_destroy(doc)
	out := encode_ok(t, doc)
	defer delete(out)
	want := `title = "x"

[a.b]
c = 1

[[fruit]]
name = "apple"

[fruit.color]
hex = "f00"

[[fruit]]
name = "pear"

[empty]
`
	testing.expect_value(t, out, want)
}

@(test)
test_encode_inline_for_mixed_arrays :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "mixed = [1, {a = 'b', c = {}}, [2, 3]]\nnone = []\npoint = { x = 1, y = 2 }\n")
	defer toml.table_destroy(doc)
	// Tables outside arrays become sections, even when the source wrote them inline.
	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, "mixed = [1, { a = \"b\", c = {} }, [2, 3]]\nnone = []\n\n[point]\nx = 1\ny = 2\n")
}

@(test)
test_encode_datetimes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
odt = 1979-05-27T00:32:00.999999-07:00
utc = 1979-05-27 07:32:00Z
east = 2001-01-01T00:00:00+05:30
ldt = 0099-01-02T03:04:05.000000001
ld = 1979-05-27
lt = 07:32:00.5
`)
	defer toml.table_destroy(doc)
	out := encode_ok(t, doc)
	defer delete(out)
	want := `odt = 1979-05-27T00:32:00.999999-07:00
utc = 1979-05-27T07:32:00Z
east = 2001-01-01T00:00:00+05:30
ldt = 0099-01-02T03:04:05.000000001
ld = 1979-05-27
lt = 07:32:00.5
`
	testing.expect_value(t, out, want)
}

@(test)
test_encode_round_trips :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_round_trip(t, SPEC_EXAMPLE)
	expect_round_trip(t, "a.b.c = 1\na.b.d = [1, 2.5, 'three', { four = 4 }]\n[x.y]\nz = 1979-05-27\n")
	expect_round_trip(t, "[[a]]\n[[a.b]]\nc = 1\n[[a.b]]\n[[a]]\nd = { e = [ { f = nan } ] }\n")
	expect_round_trip(t, "\"key with \\\"quotes\\\"\" = '''multi\nline'''\n\"\" = { \"\" = '' }\n")
	expect_round_trip(t, "nested = [[[]], [[1]], [{}]]\nunicode = \"\\U0001F600 é \\u0001\"\n")
}

@(test)
test_encode_rejects_nil_values :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)
	toml.table_set(doc, "missing", nil)
	out, err := toml.encode(doc)
	testing.expect_value(t, err, toml.Error(toml.Encode_Error.Nil_Value))
	testing.expect_value(t, out, "")

	_, nil_root := toml.encode(nil)
	testing.expect_value(t, nil_root, toml.Error(toml.Encode_Error.Nil_Value))
}

@(test)
test_write_streams_to_builder :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "a = 1\n")
	defer toml.table_destroy(doc)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "# generated\n")
	testing.expect_value(t, toml.write(strings.to_writer(&b), doc), nil)
	testing.expect_value(t, strings.to_string(b), "# generated\na = 1\n")
}

@(test)
test_build_tree_with_table_and_array_api :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc, _ := toml.table_make()
	defer toml.table_destroy(doc)

	server, _ := toml.table_make()
	testing.expect_value(t, toml.table_set(server, "host", strings.clone("localhost")), nil)
	testing.expect_value(t, toml.table_set(server, "port", i64(8080)), nil)
	ports, _ := toml.array_make()
	testing.expect_value(t, toml.array_append(ports, i64(80)), nil)
	testing.expect_value(t, toml.array_append(ports, i64(443)), nil)
	testing.expect_value(t, toml.table_set(server, "ports", ports), nil)
	testing.expect_value(t, toml.table_set(doc, "server", server), nil)

	// Replacing a value frees the old one and keeps the key's position.
	key := strings.clone("name")
	testing.expect_value(t, toml.table_set(doc, key, strings.clone("first")), nil)
	delete(key)
	testing.expect_value(t, toml.table_set(doc, "name", strings.clone("second")), nil)
	testing.expect_value(t, len(doc.keys), 2)

	out := encode_ok(t, doc)
	defer delete(out)
	testing.expect_value(t, out, "name = \"second\"\n\n[server]\nhost = \"localhost\"\nport = 8080\nports = [80, 443]\n")
}

@(test)
test_getters_follow_paths :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "n = 1\nf = 2.0\n[a.b]\ns = 'x'\nok = true\narr = [1]\n")
	defer toml.table_destroy(doc)

	s, s_found := toml.get_string(doc, "a", "b", "s")
	testing.expect(t, s_found && s == "x")
	_, wrong_type := toml.get_int(doc, "a", "b", "s")
	testing.expect(t, !wrong_type, "a string isn't an int")
	_, int_as_float := toml.get_float(doc, "n")
	testing.expect(t, !int_as_float, "integers aren't converted to floats")
	_, through_scalar := toml.get(doc, "n", "deeper")
	testing.expect(t, !through_scalar, "a path can't continue through a scalar")
	_, missing := toml.get(doc, "a", "nope")
	testing.expect(t, !missing)
	_, empty_path := toml.get(doc)
	testing.expect(t, !empty_path)
	_, nil_table := toml.get(nil, "a")
	testing.expect(t, !nil_table)

	b, b_found := toml.get_table(doc, "a", "b")
	testing.expect(t, b_found && len(b.keys) == 3)
	arr, arr_found := toml.get_array(b, "arr")
	testing.expect(t, arr_found && len(arr.items) == 1)
	ok, _ := toml.get_bool(b, "ok")
	testing.expect(t, ok)
	direct, direct_found := toml.table_get(b, "s")
	testing.expect(t, direct_found && direct.(string) == "x")
}

@(test)
test_value_equal_compares_structure :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	a := parse_ok(t, "x = 1\ny = [1, 'a', nan]\n[t]\nz = 1979-05-27\n")
	defer toml.table_destroy(a)
	reordered := parse_ok(t, "y = [1, 'a', nan]\nx = 1\n[t]\nz = 1979-05-27\n")
	defer toml.table_destroy(reordered)
	different := parse_ok(t, "x = 1.0\ny = [1, 'a', nan]\n[t]\nz = 1979-05-27\n")
	defer toml.table_destroy(different)

	testing.expect(t, toml.value_equal(a, reordered), "key order doesn't matter")
	testing.expect(t, !toml.value_equal(a, different), "1 and 1.0 differ")
	testing.expect(t, toml.value_equal(i64(3), i64(3)))
	testing.expect(t, !toml.value_equal(i64(3), "3"))
	testing.expect(t, toml.value_equal(nil, nil))
	testing.expect(t, !toml.value_equal(toml.Date{2000, 1, 1}, toml.Date{2000, 1, 2}))
}

@(test)
test_value_destroy_frees_standalone_values :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	arr, _ := toml.array_make()
	inner, _ := toml.table_make()
	toml.table_set(inner, "k", strings.clone("v"))
	toml.array_append(arr, inner)
	toml.array_append(arr, strings.clone("s"))
	toml.value_destroy(arr)
	toml.value_destroy(strings.clone("loose"))
	toml.value_destroy(i64(1))
	toml.table_destroy(nil)
	toml.array_destroy(nil)
}
