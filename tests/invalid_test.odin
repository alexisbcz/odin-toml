package toml_tests

import toml ".."
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_invalid_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"= 1", .Expected_Key},
			{"a. = 1", .Expected_Key},
			{".a = 1", .Expected_Key},
			{"a..b = 1", .Expected_Key},
			{`"""key""" = 1`, .Expected_Key},
			{`'''key''' = 1`, .Expected_Key},
			{"a b = 1", .Expected_Equals},
			{"ke$y = 1", .Expected_Equals},
			{"key", .Expected_Equals},
			{"key\n= 1", .Expected_Equals},
			{`"key = 1`, .Unterminated_String},
		},
	)
}

@(test)
test_invalid_missing_value :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = ", .Expected_Value},
			{"a =\nb = 1", .Expected_Value},
			{"a = # comment", .Expected_Value},
			{"a = truthy", .Expected_Value},
			{"a = True", .Expected_Value},
			{"a = NaN", .Expected_Value},
			{"a = infinity", .Expected_Value},
			{"a = _1", .Expected_Value},
			{"a = +", .Expected_Value},
		},
	)
}

@(test)
test_invalid_duplicate_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 1\na = 2", .Duplicate_Key},
			{"a = 1\n\"a\" = 2", .Duplicate_Key},
			{"\"\" = 1\n'' = 2", .Duplicate_Key},
			{"a.b = 1\na.b = 2", .Duplicate_Key},
			{"a.b = 1\na = 2", .Duplicate_Key},
			{"[t]\na = 1\na = 2", .Duplicate_Key},
			{"a = { b = 1, b = 2 }", .Duplicate_Key},
			{"[a]\nb = 1\n[a.b]", .Duplicate_Key},
		},
	)
}

@(test)
test_invalid_table_redefinition :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"[a]\n[a]", .Duplicate_Table},
			{"[a.b]\n[a]\n[a]", .Duplicate_Table},
			{"[a]\nb.c = 1\n[a.b]", .Duplicate_Table},
			{"a.b = 1\n[a]", .Duplicate_Table},
			{"[[a]]\n[a]", .Duplicate_Table},
			{"[a]\n[[a]]", .Duplicate_Table},
			{"a = {}\n[a]", .Duplicate_Key},
			{"a = 1\n[a]", .Duplicate_Key},
			{"a = 1\n[[a]]", .Duplicate_Key},
		},
	)
}

@(test)
test_invalid_dotted_key_into_header_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"[a.b.c]\nz = 9\n[a]\nb.c.t = 9", .Duplicate_Table},
			{"[a.b]\n[a]\nb.x = 1", .Duplicate_Table},
			{"[[a.b]]\n[a]\nb.y = 2", .Not_A_Table},
			{"a = 1\na.b = 2", .Not_A_Table},
			{"a = 'x'\n[a.b]", .Not_A_Table},
		},
	)
}

@(test)
test_invalid_inline_table_extension :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = {b = 1}\n[a.c]", .Inline_Table_Is_Immutable},
			{"a = {b = {c = 1}}\n[a.b]", .Inline_Table_Is_Immutable},
			{"a = {}\na.b = 1", .Inline_Table_Is_Immutable},
			{"a = {b.c = 1}\na.b.d = 2", .Inline_Table_Is_Immutable},
			{"a = {b.c = 1}\n[a.b.d]", .Inline_Table_Is_Immutable},
			{"a = {}\n[[a.b]]", .Inline_Table_Is_Immutable},
			{"t = { a = { b = 1 }, a.c = 2 }", .Inline_Table_Is_Immutable},
		},
	)
}

@(test)
test_invalid_static_array_extension :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = []\n[[a]]", .Static_Array_Is_Immutable},
			{"a = [{x = 1}]\n[[a]]", .Static_Array_Is_Immutable},
			{"a = [{x = 1}]\n[a.c]", .Static_Array_Is_Immutable},
			{"a = [1]\na.b = 2", .Not_A_Table},
		},
	)
}

@(test)
test_invalid_inline_table_syntax :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = { b = 1, }", .Trailing_Comma_In_Inline_Table},
			{"a = { b = 1\n}", .Expected_Comma_Or_Brace},
			{"a = {\nb = 1}", .Expected_Key},
			{"a = { b = 1 c = 2 }", .Expected_Comma_Or_Brace},
			{"a = { b = 1", .Unexpected_Eof},
			{"a = { , }", .Expected_Key},
			{"a = { b }", .Expected_Equals},
			{"a = { b = 1 }}", .Expected_Newline},
			{"a = { b = 1 # c\n}", .Expected_Comma_Or_Brace},
		},
	)
}

@(test)
test_invalid_array_syntax :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = [1 2]", .Expected_Comma_Or_Bracket},
			{"a = [1,,2]", .Expected_Value},
			{"a = [,]", .Expected_Value},
			{"a = [1", .Unexpected_Eof},
			{"a = [1,\n", .Unexpected_Eof},
			{"a = [1]]", .Expected_Newline},
			{"a = [ b = 1 ]", .Expected_Value},
			{"a = [1, 'x' 'y']", .Expected_Comma_Or_Bracket},
		},
	)
}

@(test)
test_invalid_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{`a = "abc`, .Unterminated_String},
			{"a = \"abc\n\"", .Unterminated_String},
			{"a = \"a\rb\"", .Unterminated_String},
			{`a = 'abc`, .Unterminated_String},
			{"a = 'ab\nc'", .Unterminated_String},
			{`a = """abc`, .Unterminated_String},
			{`a = '''abc''`, .Unterminated_String},
			{`a = "abc"def"`, .Expected_Newline},
			{`a = """""""""`, .Expected_Newline},
			{`a = '''''''''`, .Expected_Newline},
			{"a = \"a\x00b\"", .Invalid_Control_Character},
			{"a = \"a\x1fb\"", .Invalid_Control_Character},
			{"a = 'a\x7fb'", .Invalid_Control_Character},
			{"a = \"\"\"a\x01\"\"\"", .Invalid_Control_Character},
			{"a = '''a\x08'''", .Invalid_Control_Character},
		},
	)
}

@(test)
test_invalid_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{`a = "\x41"`, .Invalid_Escape},
			{`a = "\a"`, .Invalid_Escape},
			{`a = "\ "`, .Invalid_Escape},
			{`a = "\e"`, .Invalid_Escape},
			{`a = "\`, .Invalid_Escape},
			{`a = """\ x"""`, .Invalid_Escape},
			{`a = """\q"""`, .Invalid_Escape},
		},
	)
}

@(test)
test_invalid_unicode_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{`a = "\uD800"`, .Invalid_Unicode_Escape},
			{`a = "\uDFFF"`, .Invalid_Unicode_Escape},
			{`a = "\U00110000"`, .Invalid_Unicode_Escape},
			{`a = "\U0000D800"`, .Invalid_Unicode_Escape},
			{`a = "\u12"`, .Invalid_Unicode_Escape},
			{`a = "\uGHIJ"`, .Invalid_Unicode_Escape},
			{`a = "\U0000"`, .Invalid_Unicode_Escape},
		},
	)
}

@(test)
test_invalid_integers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 012", .Invalid_Integer},
			{"a = 00", .Invalid_Integer},
			{"a = 0_1", .Invalid_Integer},
			{"a = -01", .Invalid_Integer},
			{"a = 1__2", .Invalid_Integer},
			{"a = 1_", .Invalid_Integer},
			{"a = 1x", .Invalid_Integer},
			{"a = +0x1", .Invalid_Integer},
			{"a = -0o7", .Invalid_Integer},
			{"a = 0x", .Invalid_Integer},
			{"a = 0xG", .Invalid_Integer},
			{"a = 0x_1", .Invalid_Integer},
			{"a = 0x1_", .Invalid_Integer},
			{"a = 0X1", .Invalid_Integer},
			{"a = 0o8", .Invalid_Integer},
			{"a = 0b2", .Invalid_Integer},
			{"a = 1 2", .Expected_Newline},
		},
	)
}

@(test)
test_invalid_integer_overflow :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 9223372036854775808", .Integer_Overflow},
			{"a = -9223372036854775809", .Integer_Overflow},
			{"a = 99999999999999999999999", .Integer_Overflow},
			{"a = 0x8000000000000000", .Integer_Overflow},
			{"a = 0o1777777777777777777777", .Integer_Overflow},
			{"a = 0b1_0000000000000000000000000000000000000000000000000000000000000000", .Integer_Overflow},
		},
	)
}

@(test)
test_invalid_floats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 1.", .Invalid_Float},
			{"a = 1.e5", .Invalid_Float},
			{"a = 1e", .Invalid_Float},
			{"a = 1e+", .Invalid_Float},
			{"a = 1.0E+", .Invalid_Float},
			{"a = 01.5", .Invalid_Float},
			{"a = 1._5", .Invalid_Float},
			{"a = 1.5_", .Invalid_Float},
			{"a = 1_.5", .Invalid_Float},
			{"a = 1.2.3", .Invalid_Float},
			{"a = 1e5.0", .Invalid_Float},
			{"a = 1e_5", .Invalid_Float},
			{"a = 1e400", .Invalid_Float},
			{"a = .5", .Expected_Value},
			{"a = -.5", .Expected_Value},
		},
	)
}

@(test)
test_invalid_datetimes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 1979-13-01", .Invalid_Datetime},
			{"a = 1979-00-01", .Invalid_Datetime},
			{"a = 1979-02-30", .Invalid_Datetime},
			{"a = 1900-02-29", .Invalid_Datetime},
			{"a = 1979-04-31", .Invalid_Datetime},
			{"a = 1979-05-00", .Invalid_Datetime},
			{"a = 1979-5-27", .Invalid_Datetime},
			{"a = 1979-05-7", .Invalid_Datetime},
			{"a = 1979-05-277", .Invalid_Datetime},
			{"a = 1979-05-27T", .Invalid_Datetime},
			{"a = 1979-05-27T25:00:00", .Invalid_Datetime},
			{"a = 1979-05-27T07:60:00", .Invalid_Datetime},
			{"a = 1979-05-27T07:32:61", .Invalid_Datetime},
			{"a = 1979-05-27T7:32:00", .Invalid_Datetime},
			{"a = 1979-05-27 07:32", .Invalid_Datetime},
			{"a = 1979-05-27T07:32:00.", .Invalid_Datetime},
			{"a = 1979-05-27T07:32:00+25:00", .Invalid_Datetime},
			{"a = 1979-05-27T07:32:00+07", .Invalid_Datetime},
			{"a = 1979-05-27T07:32:00-07:60", .Invalid_Datetime},
			{"a = 07:32", .Invalid_Datetime},
			{"a = 07:32:0", .Invalid_Datetime},
			{"a = 24:00:00", .Invalid_Datetime},
		},
	)
}

@(test)
test_invalid_control_characters_in_comments :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"# a\x01b", .Invalid_Control_Character},
			{"a = 1 # \x7f", .Invalid_Control_Character},
			{"# \x00", .Invalid_Control_Character},
			{"[t] # \x1b[31m", .Invalid_Control_Character},
		},
	)

	// A tab is the one control character that comments may hold.
	doc := parse_ok(t, "a = 1 #\tfine\n")
	toml.table_destroy(doc)
}

@(test)
test_invalid_bare_carriage_return :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = 1\rb = 2", .Bare_Carriage_Return},
			{"\r", .Bare_Carriage_Return},
			{"# comment\rx = 1", .Bare_Carriage_Return},
			{"a = '''x\ry'''", .Bare_Carriage_Return},
			{"a = \"\"\"x\ry\"\"\"", .Bare_Carriage_Return},
			{"a = [1,\r2]", .Bare_Carriage_Return},
		},
	)
}

@(test)
test_invalid_utf8 :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"a = \"\xff\"", .Invalid_Utf8},
			{"a = '\xc3'", .Invalid_Utf8},
			{"# \xed\xa0\x80 is a UTF-16 surrogate", .Invalid_Utf8},
			{"\xc0\xaf = 1", .Invalid_Utf8},
		},
	)

	_, _, loc := toml.parse("ok = 1\nbad = \"\xff\"")
	testing.expect_value(t, loc, toml.Location{offset = 14, line = 2, column = 8})
}

@(test)
test_invalid_table_headers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	expect_invalid(
		t,
		{
			{"[]", .Expected_Key},
			{"[a", .Unterminated_Table_Header},
			{"[a b]", .Unterminated_Table_Header},
			{"[[a]", .Unterminated_Table_Header},
			{"[[a] ]", .Unterminated_Table_Header},
			{"[ [a]]", .Expected_Key},
			{"[a.]", .Expected_Key},
			{"[a]]", .Expected_Newline},
			{"[a] b = 1", .Expected_Newline},
			{"[\"\"\"a\"\"\"]", .Expected_Key},
		},
	)
}

@(test)
test_error_location_reports_line_and_column :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	Located :: struct {
		src:  string,
		err:  toml.Parse_Error,
		line: int,
		col:  int,
	}
	cases := []Located {
		// Columns count code points, so the two-byte é counts once.
		{"a = 1\nb = 2\nc = 'é' x", .Expected_Newline, 3, 9},
		{"a = 1\n  a = 2", .Duplicate_Key, 2, 3},
		{"[x]\n[y]\n[x]", .Duplicate_Table, 3, 2},
		{"s = \"open\nt = 1", .Unterminated_String, 1, 5},
		{"n = 0x\n", .Invalid_Integer, 1, 5},
		{"\r\n\r\nk = [1 2]", .Expected_Comma_Or_Bracket, 3, 8},
		{"x = \"\\q\"", .Invalid_Escape, 1, 6},
	}
	for c in cases {
		doc, err, loc := toml.parse(c.src)
		toml.table_destroy(doc)
		testing.expectf(t, err == toml.Error(c.err), "%q: want %v, got %v", c.src, c.err, err)
		testing.expectf(t, loc.line == c.line && loc.column == c.col, "%q: want %d:%d, got %d:%d", c.src, c.line, c.col, loc.line, loc.column)
	}
}

@(test)
test_invalid_nesting_too_deep :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	deep_arrays := strings.concatenate({"a = ", strings.repeat("[", 300, context.temp_allocator)}, context.temp_allocator)
	deep_tables := strings.concatenate({"a = ", strings.repeat("{b = ", 300, context.temp_allocator)}, context.temp_allocator)
	defer free_all(context.temp_allocator)
	expect_invalid(t, {{deep_arrays, .Nesting_Too_Deep}, {deep_tables, .Nesting_Too_Deep}})

	// Nesting within the limit parses, and frees cleanly.
	ok_depth := strings.concatenate(
		{"a = ", strings.repeat("[", 200, context.temp_allocator), strings.repeat("]", 200, context.temp_allocator)},
		context.temp_allocator,
	)
	doc := parse_ok(t, ok_depth)
	toml.table_destroy(doc)
}

@(test)
test_error_frees_partial_tree :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = tracked(&track)
	defer expect_no_leaks(t, &track)

	// A long valid prefix builds real tables, arrays and strings before the error.
	src := `
title = "partial"
[[servers]]
name = "a"
tags = ["x", "y", { z = "w" }]
[servers.meta]
k = """multi
line"""
[[servers]]
name = "b"
bad = [1, 2, oops]
`
	doc, err, loc := toml.parse(src)
	testing.expect_value(t, doc, nil)
	testing.expect_value(t, err, toml.Error(toml.Parse_Error.Expected_Value))
	testing.expect_value(t, loc.line, 11)
}
