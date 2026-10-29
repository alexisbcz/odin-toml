package toml_tests

import toml ".."
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_parse_empty_document :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	for src in ([]string{"", "\n\n", "   \t\n", "# only a comment", "# a\r\n# b\r\n"}) {
		doc := parse_ok(t, src)
		defer toml.table_destroy(doc)
		testing.expectf(t, doc != nil && len(doc.keys) == 0, "%q should give an empty table", src)
	}
}

@(test)
test_parse_comments_and_crlf :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "# header\r\na = 1 # trailing\r\n\r\n[t] # table\r\nb = \"x\"#tight\r\n")
	defer toml.table_destroy(doc)
	a, _ := toml.get_int(doc, "a")
	b, _ := toml.get_string(doc, "t", "b")
	testing.expect_value(t, a, 1)
	testing.expect_value(t, b, "x")
}

@(test)
test_parse_bare_and_quoted_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
bare_key = 1
bare-key = 2
1234 = 3
"quoted key" = 4
"ʎǝʞ" = 5
'literal "key"' = 6
"" = 7
"esc\tkey" = 8
true = 9
`)
	defer toml.table_destroy(doc)
	want := []struct {
		key:   string,
		value: i64,
	}{{"bare_key", 1}, {"bare-key", 2}, {"1234", 3}, {"quoted key", 4}, {"ʎǝʞ", 5}, {`literal "key"`, 6}, {"", 7}, {"esc\tkey", 8}, {"true", 9}}
	for w in want {
		got, found := toml.get_int(doc, w.key)
		testing.expectf(t, found && got == w.value, "key %q: got %v (found %v)", w.key, got, found)
	}
}

@(test)
test_parse_dotted_keys_create_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
name = "Orange"
physical.color = "orange"
physical.shape = "round"
site."google.com" = true
a . b  .	c = 1
3.14159 = "pi"
`)
	defer toml.table_destroy(doc)
	color, _ := toml.get_string(doc, "physical", "color")
	shape, _ := toml.get_string(doc, "physical", "shape")
	google, _ := toml.get_bool(doc, "site", "google.com")
	c, _ := toml.get_int(doc, "a", "b", "c")
	pi, _ := toml.get_string(doc, "3", "14159")
	testing.expect_value(t, color, "orange")
	testing.expect_value(t, shape, "round")
	testing.expect_value(t, google, true)
	testing.expect_value(t, c, 1)
	testing.expect_value(t, pi, "pi")
}

@(test)
test_parse_basic_string_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `s = "tab\tquote\"back\\slash\nnl\rcr\bbs\fff"`)
	defer toml.table_destroy(doc)
	s, _ := toml.get_string(doc, "s")
	testing.expect_value(t, s, "tab\tquote\"back\\slash\nnl\rcr\bbs\fff")
}

@(test)
test_parse_unicode_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
a = "\u00E9"
b = "\U0001F600"
c = "\u0000"
`)
	defer toml.table_destroy(doc)
	a, _ := toml.get_string(doc, "a")
	b, _ := toml.get_string(doc, "b")
	c, _ := toml.get_string(doc, "c")
	testing.expect_value(t, a, "é")
	testing.expect_value(t, b, "😀")
	testing.expect_value(t, c, "\x00")
}

@(test)
test_parse_literal_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
winpath = 'C:\Users\nodejs\templates'
quoted = 'Tom "Dubs" Preston-Werner'
regex = '<\i\c*\s*>'
empty = ''
tab = '	'
`)
	defer toml.table_destroy(doc)
	winpath, _ := toml.get_string(doc, "winpath")
	quoted, _ := toml.get_string(doc, "quoted")
	regex, _ := toml.get_string(doc, "regex")
	empty, found := toml.get_string(doc, "empty")
	tab, _ := toml.get_string(doc, "tab")
	testing.expect_value(t, winpath, `C:\Users\nodejs\templates`)
	testing.expect_value(t, quoted, `Tom "Dubs" Preston-Werner`)
	testing.expect_value(t, regex, `<\i\c*\s*>`)
	testing.expect(t, found && empty == "")
	testing.expect_value(t, tab, "\t")
}

@(test)
test_parse_multiline_basic_trims_first_newline :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "a = \"\"\"\nRoses are red\nViolets are blue\"\"\"\nb = \"\"\"\"\"\"\nc = \"\"\"\n\n x\"\"\"\n")
	defer toml.table_destroy(doc)
	a, _ := toml.get_string(doc, "a")
	b, _ := toml.get_string(doc, "b")
	c, _ := toml.get_string(doc, "c")
	testing.expect_value(t, a, "Roses are red\nViolets are blue")
	testing.expect_value(t, b, "")
	testing.expect_value(t, c, "\n x")
}

@(test)
test_parse_multiline_line_ending_backslash :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	src := "s = \"\"\"\nThe quick brown \\\n\n\n  fox jumps over \\   \n    the lazy dog.\"\"\"\ncrlf = \"\"\"a\\\r\n   b\"\"\"\n"
	doc := parse_ok(t, src)
	defer toml.table_destroy(doc)
	s, _ := toml.get_string(doc, "s")
	crlf, _ := toml.get_string(doc, "crlf")
	testing.expect_value(t, s, "The quick brown fox jumps over the lazy dog.")
	testing.expect_value(t, crlf, "ab")
}

@(test)
test_parse_multiline_quotes_near_delimiter :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
a = """Here are two quotation marks: "". Simple enough."""
b = """Here are three quotation marks: ""\"."""
c = """"This," she said, "is just a pointless statement.""""
d = '''Here are fifteen apostrophes: '''''
e = ''''one quote' at both ends''''
`)
	defer toml.table_destroy(doc)
	a, _ := toml.get_string(doc, "a")
	b, _ := toml.get_string(doc, "b")
	c, _ := toml.get_string(doc, "c")
	d, _ := toml.get_string(doc, "d")
	e, _ := toml.get_string(doc, "e")
	testing.expect_value(t, a, `Here are two quotation marks: "". Simple enough.`)
	testing.expect_value(t, b, `Here are three quotation marks: """.`)
	testing.expect_value(t, c, `"This," she said, "is just a pointless statement."`)
	testing.expect_value(t, d, `Here are fifteen apostrophes: ''`)
	testing.expect_value(t, e, `'one quote' at both ends'`)
}

@(test)
test_parse_multiline_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "lines = '''\nThe first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved. \\n stays\n'''\n")
	defer toml.table_destroy(doc)
	lines, _ := toml.get_string(doc, "lines")
	testing.expect_value(t, lines, "The first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved. \\n stays\n")
}

@(test)
test_parse_multiline_crlf_normalizes_to_lf :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "a = \"\"\"\r\none\r\ntwo\"\"\"\r\nb = '''\r\nx\r\ny'''\r\n")
	defer toml.table_destroy(doc)
	a, _ := toml.get_string(doc, "a")
	b, _ := toml.get_string(doc, "b")
	testing.expect_value(t, a, "one\ntwo")
	testing.expect_value(t, b, "x\ny")
}

@(test)
test_parse_decimal_integers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
a = +99
b = 42
c = 0
d = -17
e = 1_000
f = 5_349_221
g = 53_49_221
h = 1_2_3_4_5
i = +0
j = -0
`)
	defer toml.table_destroy(doc)
	want := []struct {
		key:   string,
		value: i64,
	}{{"a", 99}, {"b", 42}, {"c", 0}, {"d", -17}, {"e", 1000}, {"f", 5349221}, {"g", 5349221}, {"h", 12345}, {"i", 0}, {"j", 0}}
	for w in want {
		got, found := toml.get_int(doc, w.key)
		testing.expectf(t, found && got == w.value, "%s: got %v", w.key, got)
	}
}

@(test)
test_parse_integer_limits :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "max = 9223372036854775807\nmin = -9223372036854775808\nhex = 0x7FFFFFFFFFFFFFFF\n")
	defer toml.table_destroy(doc)
	hi, _ := toml.get_int(doc, "max")
	lo, _ := toml.get_int(doc, "min")
	hex, _ := toml.get_int(doc, "hex")
	testing.expect_value(t, hi, max(i64))
	testing.expect_value(t, lo, min(i64))
	testing.expect_value(t, hex, max(i64))
}

@(test)
test_parse_hex_octal_binary :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
hex1 = 0xDEADBEEF
hex2 = 0xdeadbeef
hex3 = 0xdead_beef
hex4 = 0x00ff
oct1 = 0o01234567
oct2 = 0o755
bin1 = 0b11010110
bin2 = 0b0000_0001
`)
	defer toml.table_destroy(doc)
	want := []struct {
		key:   string,
		value: i64,
	}{{"hex1", 0xDEADBEEF}, {"hex2", 0xDEADBEEF}, {"hex3", 0xDEADBEEF}, {"hex4", 255}, {"oct1", 0o01234567}, {"oct2", 0o755}, {"bin1", 0b11010110}, {"bin2", 1}}
	for w in want {
		got, found := toml.get_int(doc, w.key)
		testing.expectf(t, found && got == w.value, "%s: got %v", w.key, got)
	}
}

@(test)
test_parse_floats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
a = +1.0
b = 3.1415
c = -0.01
d = 5e+22
e = 1e06
f = -2E-2
g = 6.626e-34
h = 224_617.445_991_228
i = 0.0
j = -0.0
k = 1e1_0
`)
	defer toml.table_destroy(doc)
	want := []struct {
		key:   string,
		value: f64,
	}{{"a", 1}, {"b", 3.1415}, {"c", -0.01}, {"d", 5e22}, {"e", 1e6}, {"f", -2e-2}, {"g", 6.626e-34}, {"h", 224617.445991228}, {"i", 0}, {"j", 0}, {"k", 1e10}}
	for w in want {
		got, found := toml.get_float(doc, w.key)
		testing.expectf(t, found && got == w.value, "%s: got %v", w.key, got)
	}
	j, _ := toml.get_float(doc, "j")
	testing.expect(t, math.sign_bit(j), "-0.0 keeps its sign")
}

@(test)
test_parse_special_floats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "a = inf\nb = +inf\nc = -inf\nd = nan\ne = +nan\nf = -nan\narr = [inf, -inf, nan]\n")
	defer toml.table_destroy(doc)
	a, _ := toml.get_float(doc, "a")
	b, _ := toml.get_float(doc, "b")
	c, _ := toml.get_float(doc, "c")
	testing.expect(t, math.is_inf(a, 1))
	testing.expect(t, math.is_inf(b, 1))
	testing.expect(t, math.is_inf(c, -1))
	for key in ([]string{"d", "e", "f"}) {
		v, found := toml.get_float(doc, key)
		testing.expectf(t, found && math.is_nan(v), "%s should be nan", key)
	}
	arr, _ := toml.get_array(doc, "arr")
	testing.expect_value(t, len(arr.items), 3)
}

@(test)
test_parse_booleans :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "yes = true\nno = false\n")
	defer toml.table_destroy(doc)
	yes, _ := toml.get_bool(doc, "yes")
	no, found := toml.get_bool(doc, "no")
	testing.expect_value(t, yes, true)
	testing.expect(t, found && !no)
}

@(test)
test_parse_offset_datetimes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
odt1 = 1979-05-27T07:32:00Z
odt2 = 1979-05-27T00:32:00-07:00
odt3 = 1979-05-27T00:32:00.999999+05:30
odt4 = 1979-05-27 07:32:00z
odt5 = 1979-05-27t07:32:00Z
`)
	defer toml.table_destroy(doc)
	want := []struct {
		key:   string,
		value: toml.Offset_Datetime,
	} {
		{"odt1", {{1979, 5, 27}, {7, 32, 0, 0}, 0}},
		{"odt2", {{1979, 5, 27}, {0, 32, 0, 0}, -420}},
		{"odt3", {{1979, 5, 27}, {0, 32, 0, 999_999_000}, 330}},
		{"odt4", {{1979, 5, 27}, {7, 32, 0, 0}, 0}},
		{"odt5", {{1979, 5, 27}, {7, 32, 0, 0}, 0}},
	}
	for w in want {
		v, _ := toml.get(doc, w.key)
		got, is_odt := v.(toml.Offset_Datetime)
		testing.expectf(t, is_odt && got == w.value, "%s: got %v", w.key, v)
	}
}

@(test)
test_parse_local_datetime :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "ldt1 = 1979-05-27T07:32:00\nldt2 = 1979-05-27T00:32:00.5\n")
	defer toml.table_destroy(doc)
	v1, _ := toml.get(doc, "ldt1")
	v2, _ := toml.get(doc, "ldt2")
	testing.expect_value(t, v1.(toml.Local_Datetime), toml.Local_Datetime{{1979, 5, 27}, {7, 32, 0, 0}})
	testing.expect_value(t, v2.(toml.Local_Datetime), toml.Local_Datetime{{1979, 5, 27}, {0, 32, 0, 500_000_000}})
}

@(test)
test_parse_local_date_and_time :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "ld = 1979-05-27\nlt1 = 07:32:00\nlt2 = 00:32:00.999999\nlate = 23:59:60\n")
	defer toml.table_destroy(doc)
	ld, _ := toml.get(doc, "ld")
	lt1, _ := toml.get(doc, "lt1")
	lt2, _ := toml.get(doc, "lt2")
	late, _ := toml.get(doc, "late")
	testing.expect_value(t, ld.(toml.Date), toml.Date{1979, 5, 27})
	testing.expect_value(t, lt1.(toml.Time), toml.Time{7, 32, 0, 0})
	testing.expect_value(t, lt2.(toml.Time), toml.Time{0, 32, 0, 999_999_000})
	testing.expect_value(t, late.(toml.Time), toml.Time{23, 59, 60, 0})
}

@(test)
test_parse_fraction_truncates_to_nanoseconds :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "t = 12:00:00.1234567899999\n")
	defer toml.table_destroy(doc)
	v, _ := toml.get(doc, "t")
	testing.expect_value(t, v.(toml.Time).nanosecond, 123_456_789)
}

@(test)
test_parse_date_space_without_time_is_date :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "d = 2000-02-29 # a leap day\narr = [1987-07-05 , 2000-01-01]\n")
	defer toml.table_destroy(doc)
	d, _ := toml.get(doc, "d")
	testing.expect_value(t, d.(toml.Date), toml.Date{2000, 2, 29})
	arr, _ := toml.get_array(doc, "arr")
	testing.expect_value(t, len(arr.items), 2)
}

@(test)
test_parse_arrays_mixed_and_nested :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
integers = [ 1, 2, 3 ]
nested = [ [ 1, 2 ], ["a", 'b', """c"""], [] ]
mixed = [ 0.1, 0.2, 1, "x", { x = 1 }, 1979-05-27 ]
empty = []
`)
	defer toml.table_destroy(doc)
	integers, _ := toml.get_array(doc, "integers")
	testing.expect_value(t, len(integers.items), 3)
	testing.expect_value(t, integers.items[2].(i64), 3)

	nested, _ := toml.get_array(doc, "nested")
	testing.expect_value(t, len(nested.items), 3)
	strs := nested.items[1].(^toml.Array)
	testing.expect_value(t, strs.items[2].(string), "c")
	testing.expect_value(t, len(nested.items[2].(^toml.Array).items), 0)

	mixed, _ := toml.get_array(doc, "mixed")
	testing.expect_value(t, len(mixed.items), 6)
	inline := mixed.items[4].(^toml.Table)
	x, _ := toml.get_int(inline, "x")
	testing.expect_value(t, x, 1)

	empty, _ := toml.get_array(doc, "empty")
	testing.expect_value(t, len(empty.items), 0)
}

@(test)
test_parse_multiline_arrays_with_comments :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "a = [\n  1, # one\n  # nothing here\n  2,\r\n  3,\n]\nb = [ # open\n]\n")
	defer toml.table_destroy(doc)
	a, _ := toml.get_array(doc, "a")
	b, _ := toml.get_array(doc, "b")
	testing.expect_value(t, len(a.items), 3)
	testing.expect_value(t, len(b.items), 0)
}

@(test)
test_parse_inline_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
name = { first = "Tom", last = "Preston-Werner" }
point = {x=1,y=2}
empty = {}
nested = { a = { b = { c = [1, { d = true }] } } }
`)
	defer toml.table_destroy(doc)
	first, _ := toml.get_string(doc, "name", "first")
	last, _ := toml.get_string(doc, "name", "last")
	y, _ := toml.get_int(doc, "point", "y")
	empty, found := toml.get_table(doc, "empty")
	c, _ := toml.get_array(doc, "nested", "a", "b", "c")
	testing.expect_value(t, first, "Tom")
	testing.expect_value(t, last, "Preston-Werner")
	testing.expect_value(t, y, 2)
	testing.expect(t, found && len(empty.keys) == 0)
	d, _ := toml.get_bool(c.items[1].(^toml.Table), "d")
	testing.expect(t, d)
}

@(test)
test_parse_inline_table_dotted_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `animal = { type.name = "pug", type.size = "small", age = 3 }`)
	defer toml.table_destroy(doc)
	name, _ := toml.get_string(doc, "animal", "type", "name")
	size, _ := toml.get_string(doc, "animal", "type", "size")
	testing.expect_value(t, name, "pug")
	testing.expect_value(t, size, "small")
}

@(test)
test_parse_table_headers_and_implicit_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
[table-1]
key1 = "some string"

[ dog . "tater.man" ]
type.name = "pug"

[x.y.z.w]
deep = true

[x] # defining a super-table afterwards is fine
top = 1
`)
	defer toml.table_destroy(doc)
	key1, _ := toml.get_string(doc, "table-1", "key1")
	pug, _ := toml.get_string(doc, "dog", "tater.man", "type", "name")
	deep, _ := toml.get_bool(doc, "x", "y", "z", "w", "deep")
	top, _ := toml.get_int(doc, "x", "top")
	testing.expect_value(t, key1, "some string")
	testing.expect_value(t, pug, "pug")
	testing.expect(t, deep)
	testing.expect_value(t, top, 1)
}

@(test)
test_parse_array_of_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
[[products]]
name = "Hammer"
sku = 738594937

[[products]]  # empty table within the array

[[products]]
name = "Nail"
color = "gray"
`)
	defer toml.table_destroy(doc)
	products, _ := toml.get_array(doc, "products")
	testing.expect_value(t, len(products.items), 3)
	hammer, _ := toml.get_string(products.items[0].(^toml.Table), "name")
	testing.expect_value(t, hammer, "Hammer")
	testing.expect_value(t, len(products.items[1].(^toml.Table).keys), 0)
	color, _ := toml.get_string(products.items[2].(^toml.Table), "color")
	testing.expect_value(t, color, "gray")
}

@(test)
test_parse_nested_array_of_tables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
[[fruits]]
name = "apple"

[fruits.physical]  # subtable
color = "red"

[[fruits.varieties]]  # nested array of tables
name = "red delicious"

[[fruits.varieties]]
name = "granny smith"

[[fruits]]
name = "banana"

[[fruits.varieties]]
name = "plantain"
`)
	defer toml.table_destroy(doc)
	fruits, _ := toml.get_array(doc, "fruits")
	testing.expect_value(t, len(fruits.items), 2)
	apple := fruits.items[0].(^toml.Table)
	color, _ := toml.get_string(apple, "physical", "color")
	testing.expect_value(t, color, "red")
	apple_varieties, _ := toml.get_array(apple, "varieties")
	testing.expect_value(t, len(apple_varieties.items), 2)
	banana_varieties, _ := toml.get_array(fruits.items[1].(^toml.Table), "varieties")
	plantain, _ := toml.get_string(banana_varieties.items[0].(^toml.Table), "name")
	testing.expect_value(t, plantain, "plantain")
}

@(test)
test_parse_subtable_of_dotted_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, `
[fruit]
apple.color = "red"
apple.taste.sweet = true

[fruit.apple.texture]  # you can add sub-tables
smooth = true
`)
	defer toml.table_destroy(doc)
	sweet, _ := toml.get_bool(doc, "fruit", "apple", "taste", "sweet")
	smooth, _ := toml.get_bool(doc, "fruit", "apple", "texture", "smooth")
	testing.expect(t, sweet)
	testing.expect(t, smooth)
}

@(test)
test_parse_keeps_key_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "zebra = 1\napple = 2\nmango = 3\n[middle]\n[alpha]\n")
	defer toml.table_destroy(doc)
	want := []string{"zebra", "apple", "mango", "middle", "alpha"}
	testing.expect_value(t, len(doc.keys), len(want))
	for key, i in doc.keys {
		testing.expect_value(t, key, want[i])
	}
}

@(test)
test_parse_skips_byte_order_mark :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, "\xef\xbb\xbfa = 1\n")
	defer toml.table_destroy(doc)
	a, found := toml.get_int(doc, "a")
	testing.expect(t, found && a == 1)
}

@(test)
test_parse_copies_strings_out_of_input :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	src := strings.clone("name = 'owned'\n['quoted key']\nbare = \"x\"\n")
	doc := parse_ok(t, src)
	defer toml.table_destroy(doc)
	delete(src)
	name, _ := toml.get_string(doc, "name")
	bare, _ := toml.get_string(doc, "quoted key", "bare")
	testing.expect_value(t, name, "owned")
	testing.expect_value(t, bare, "x")
}

@(test)
test_parse_into_arena_needs_no_destroy :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc, err, _ := toml.parse("a = [1, 2, {b = 'c'}]\n[t]\nx = 1\n", mem.dynamic_arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	x, _ := toml.get_int(doc, "t", "x")
	testing.expect_value(t, x, 1)
}

SPEC_EXAMPLE :: `
# This is a TOML document

title = "TOML Example"

[owner]
name = "Tom Preston-Werner"
dob = 1979-05-27T07:32:00-08:00

[database]
enabled = true
ports = [ 8000, 8001, 8002 ]
data = [ ["delta", "phi"], [3.14] ]
temp_targets = { cpu = 79.5, case = 72.0 }

[servers]

[servers.alpha]
ip = "10.0.0.1"
role = "frontend"

[servers.beta]
ip = "10.0.0.2"
role = "backend"
`

@(test)
test_parse_spec_example :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	doc := parse_ok(t, SPEC_EXAMPLE)
	defer toml.table_destroy(doc)
	title, _ := toml.get_string(doc, "title")
	dob, _ := toml.get(doc, "owner", "dob")
	ports, _ := toml.get_array(doc, "database", "ports")
	cpu, _ := toml.get_float(doc, "database", "temp_targets", "cpu")
	role, _ := toml.get_string(doc, "servers", "beta", "role")
	testing.expect_value(t, title, "TOML Example")
	testing.expect_value(t, dob.(toml.Offset_Datetime).offset_minutes, -480)
	testing.expect_value(t, len(ports.items), 3)
	testing.expect_value(t, cpu, 79.5)
	testing.expect_value(t, role, "backend")
}

@(test)
test_parse_assorted_valid_documents :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	docs := []string {
		"a=1",
		"  indented = true  \t\n",
		"a = 'a'#comment",
		"[a]#comment\n[b] # spaced\n",
		"\"a\".\"b\" = 1\n'c'.d = 2\n",
		"[a.\"b.c\".d]\n[\"\"]\n['b']\n",
		"\"a\\u0041\" = 1\n",
		"a = [ [ ], [ ] ]\nb = { }\n",
		"a = [\n]\n",
		"a = [1,2,]\n",
		"a = 1e+05\nb = 1E5\nc = -1E-3\nd = 0e0\ne = 0.0e-0\nf = 1_000.0_1e1_0\n",
		"a = 1987-07-05T17:45:00.123Z\nb = 00:00:00.000000000000001\n",
		"a = [1979-05-27T07:32:00Z,1979-05-27]\n",
		"[[a]]\n[a.b]\nx = 1\n[[a]]\n[a.b]\nx = 2\n",
		"[[a]]\nb.c = 1\nb.d = 2\n[[a]]\nb.c = 3\n",
		"[a]\n[a.b]\n[a.c]\n",
		"[1]\n2 = 3\n",
		"a = \"\"\"\\\\\"\"\"\n",
		"a = \"\"\"a\\\"\"\"b\"\"\"\n",
		"a = \"\"\"\n\\\n\n\"\"\"\n",
		"a = \"\\\"\"\n",
		"a = '\"'\n",
		"a = \"\xe2\x82\xac\"\n",
		"\"€\" = 1\n",
		"emoji = \"😀\"\n\"😀\" = 1\n",
		"x = -inf\ny = +nan\n",
		"key = \"é\" # é in a comment\n",
		"a = 1 # comment with \ttab and unicode ✓\n",
		"[[ a ]]\n[ a . b ]\n",
		"t = { a.b.c = 1, a.b.d = 2, e = [ { f = 1 } ] }\n",
		"a.b = 1\n[a.c]\n",
		"x.y.z = 1\nx.y.w = 2\n",
		"[a]\nb.c.d = 1\n[a.b.e]\nf = 2\n",
		"[x.y]\n[x]\nz.w = 1\n",
		"true = true\nfalse = false\ninf = inf\nnan = nan\n",
		"0x1 = 1\n1e5 = 2\n",
		"a = 2000-02-29T23:59:60Z\n",
		"\n\n\n# lots of blank lines\n\n\na = 1\n\n\n",
	}
	for src in docs {
		doc, err, at := toml.parse(src)
		testing.expectf(t, err == nil, "%q: unexpected %v at %d:%d", src, err, at.line, at.column)
		toml.table_destroy(doc)
	}
}
