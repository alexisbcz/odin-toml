package toml

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

/*
parse reads a TOML 1.0 document.

Inputs:
- data: the document text. parse copies every string it keeps, so `data` may
  be freed as soon as parse returns. A leading UTF-8 byte order mark is skipped.
- allocator: allocates every node of the returned tree, and the parser's
  scratch state, which it frees before returning.

Returns:
- root: the top-level table, owned by the caller; free it with table_destroy.
  It's nil when `err` isn't.
- err: nil on success, a Parse_Error for malformed input, or an allocator error.
- loc: where the error was found. It's the zero Location on success.

Example:
	doc, err, loc := toml.parse(`answer = 42`)
	if err != nil {
		fmt.eprintfln("line %d, column %d: %v", loc.line, loc.column, err)
		return
	}
	defer toml.table_destroy(doc)
*/
parse :: proc(data: string, allocator := context.allocator) -> (root: ^Table, err: Error, loc: Location) {
	if bad := find_invalid_utf8(data); bad >= 0 {
		return nil, .Invalid_Utf8, location_at(data, bad)
	}

	p := Parser {
		src       = data,
		allocator = allocator,
	}
	if strings.has_prefix(data, "\xef\xbb\xbf") {
		p.pos = 3
	}
	p.kinds = make(map[^Table]Table_Kind, allocator)
	p.headers = make(map[^Array]struct{}, allocator)
	defer {
		delete(p.kinds)
		delete(p.headers)
	}

	p.root, err = table_make(allocator)
	if err != nil {
		return nil, err, location_at(data, 0)
	}
	err = mark_table(&p, p.root, .Explicit)
	if err == nil {
		p.current = p.root
		err = parse_document(&p)
	}
	if err != nil {
		table_destroy(p.root)
		return nil, err, location_at(data, p.err_pos)
	}
	return p.root, nil, {}
}

// Table_Kind records how a mutable table came to exist, which decides what may extend it later.
@(private)
Table_Kind :: enum u8 {
	// Created along a header path, such as `a` in `[a.b]`. A later `[a]` may still define it.
	Implicit,
	// Defined by its own `[header]` or `[[header]]`.
	Explicit,
	// Created by a dotted key, such as `a` in `a.b = 1`. Only more dotted keys may extend it.
	Dotted,
}

@(private)
Parser :: struct {
	src:       string,
	pos:       int,
	allocator: runtime.Allocator,
	root:      ^Table,
	current:   ^Table,
	// Every table that a header or dotted key may still extend. Inline tables are absent.
	kinds:     map[^Table]Table_Kind,
	// Arrays created by `[[header]]`; arrays written with `[ ]` are absent.
	headers:   map[^Array]struct{},
	// How many tables and arrays below the root the value being parsed sits.
	depth:     int,
	err_pos:   int,
}

@(private = "file")
fail :: proc(p: ^Parser, err: Parse_Error, pos: int) -> Error {
	p.err_pos = pos
	return err
}

@(private = "file")
at_end :: #force_inline proc(p: ^Parser) -> bool {
	return p.pos >= len(p.src)
}

@(private = "file")
peek :: #force_inline proc(p: ^Parser) -> byte {
	return p.src[p.pos] if p.pos < len(p.src) else 0
}

@(private = "file")
is_control :: #force_inline proc(c: byte) -> bool {
	return (c < 0x20 && c != '\t') || c == 0x7f
}

@(private = "file")
is_digit :: #force_inline proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_bare_key_char :: #force_inline proc(c: byte) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '-':
		return true
	}
	return false
}

@(private = "file")
skip_whitespace :: proc(p: ^Parser) {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {
		p.pos += 1
	}
}

// skip_comment consumes a comment that starts at `#`, stopping before the newline.
@(private = "file")
skip_comment :: proc(p: ^Parser) -> Error {
	p.pos += 1
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == '\n' {
			return nil
		}
		if c == '\r' {
			if p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n' {
				return nil
			}
			return fail(p, .Bare_Carriage_Return, p.pos)
		}
		if is_control(c) {
			return fail(p, .Invalid_Control_Character, p.pos)
		}
		p.pos += 1
	}
	return nil
}

// eat_newline consumes one LF or CRLF and reports whether it found one.
@(private = "file")
eat_newline :: proc(p: ^Parser) -> (found: bool, err: Error) {
	switch peek(p) {
	case '\n':
		p.pos += 1
		return true, nil
	case '\r':
		if p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n' {
			p.pos += 2
			return true, nil
		}
		return false, fail(p, .Bare_Carriage_Return, p.pos)
	}
	return false, nil
}

// skip_trivia consumes whitespace, comments and newlines, as allowed inside arrays.
@(private = "file")
skip_trivia :: proc(p: ^Parser) -> Error {
	for {
		skip_whitespace(p)
		if at_end(p) {
			return nil
		}
		if p.src[p.pos] == '#' {
			skip_comment(p) or_return
			continue
		}
		if !(eat_newline(p) or_return) {
			return nil
		}
	}
}

// expect_line_end requires the rest of the line to hold only whitespace and an optional comment.
@(private = "file")
expect_line_end :: proc(p: ^Parser) -> Error {
	skip_whitespace(p)
	if !at_end(p) && p.src[p.pos] == '#' {
		skip_comment(p) or_return
	}
	if at_end(p) {
		return nil
	}
	if !(eat_newline(p) or_return) {
		return fail(p, .Expected_Newline, p.pos)
	}
	return nil
}

@(private = "file")
parse_document :: proc(p: ^Parser) -> Error {
	for {
		skip_whitespace(p)
		if at_end(p) {
			return nil
		}
		switch p.src[p.pos] {
		case '#':
			skip_comment(p) or_return
		case '\n', '\r':
			_ = eat_newline(p) or_return
		case '[':
			parse_header(p) or_return
		case:
			parse_key_value(p, p.current) or_return
			expect_line_end(p) or_return
		}
	}
}

@(private = "file")
mark_table :: proc(p: ^Parser, t: ^Table, kind: Table_Kind) -> Error {
	_, slot, _, err := map_entry(&p.kinds, t)
	if err != nil {
		return err
	}
	slot^ = kind
	return nil
}

// unmark_inline forgets the dotted subtables of a finished inline table, which freezes them.
@(private = "file")
unmark_inline :: proc(p: ^Parser, t: ^Table) {
	for key in t.keys {
		if sub, is_table := t.values[key].(^Table); is_table && sub in p.kinds {
			delete_key(&p.kinds, sub)
			unmark_inline(p, sub)
		}
	}
}

// add_table creates an empty table under `key` in `parent`, which must not hold `key` yet.
@(private = "file")
add_table :: proc(p: ^Parser, parent: ^Table, key: string, kind: Table_Kind) -> (t: ^Table, err: Error) {
	t = table_make(p.allocator) or_return
	if err = table_set(parent, key, t); err != nil {
		table_destroy(t)
		return nil, err
	}
	mark_table(p, t, kind) or_return
	return t, nil
}

// add_array_element appends a fresh table to an array of tables.
@(private = "file")
add_array_element :: proc(p: ^Parser, a: ^Array) -> (t: ^Table, err: Error) {
	t = table_make(p.allocator) or_return
	if err = array_append(a, t); err != nil {
		table_destroy(t)
		return nil, err
	}
	mark_table(p, t, .Explicit) or_return
	return t, nil
}

@(private = "file")
destroy_key :: proc(parts: [dynamic]string, allocator: runtime.Allocator) {
	for part in parts {
		delete(part, allocator)
	}
	delete(parts)
}

// parse_key reads a possibly dotted key. The caller frees the parts with destroy_key.
@(private = "file")
parse_key :: proc(p: ^Parser) -> (parts: [dynamic]string, err: Error) {
	parts = make([dynamic]string, 0, 4, p.allocator) or_return
	defer if err != nil {
		destroy_key(parts, p.allocator)
	}
	for {
		skip_whitespace(p)
		part := parse_simple_key(p) or_return
		if _, append_err := append(&parts, part); append_err != nil {
			delete(part, p.allocator)
			return parts, append_err
		}
		skip_whitespace(p)
		if peek(p) != '.' {
			return parts, nil
		}
		p.pos += 1
	}
}

@(private = "file")
parse_simple_key :: proc(p: ^Parser) -> (key: string, err: Error) {
	if at_end(p) {
		return "", fail(p, .Expected_Key, p.pos)
	}
	rest := p.src[p.pos:]
	switch {
	case strings.has_prefix(rest, `"""`), strings.has_prefix(rest, `'''`):
		// Multi-line strings can't be keys.
		return "", fail(p, .Expected_Key, p.pos)
	case rest[0] == '"':
		return parse_basic_string(p)
	case rest[0] == '\'':
		return parse_literal_string(p)
	case is_bare_key_char(rest[0]):
		start := p.pos
		for p.pos < len(p.src) && is_bare_key_char(p.src[p.pos]) {
			p.pos += 1
		}
		return clone_string(p.src[start:p.pos], p.allocator)
	}
	return "", fail(p, .Expected_Key, p.pos)
}

// parse_key_value reads `key = value` into `t`, creating tables for dotted keys.
@(private = "file")
parse_key_value :: proc(p: ^Parser, t: ^Table) -> Error {
	key_pos := p.pos
	parts := parse_key(p) or_return
	defer destroy_key(parts, p.allocator)

	if peek(p) != '=' {
		return fail(p, .Expected_Equals, p.pos)
	}
	p.pos += 1
	skip_whitespace(p)

	// Each dotted part but the last is a table one level below the previous one.
	saved_depth := p.depth
	defer p.depth = saved_depth
	p.depth += len(parts) - 1
	if p.depth > MAX_NESTING_DEPTH {
		return fail(p, .Nesting_Too_Deep, key_pos)
	}

	target := t
	for part in parts[:len(parts) - 1] {
		target = enter_dotted(p, target, part, key_pos) or_return
	}
	last := parts[len(parts) - 1]
	if last in target.values {
		return fail(p, .Duplicate_Key, key_pos)
	}

	value := parse_value(p) or_return
	if err := table_set(target, last, value); err != nil {
		value_destroy(value, p.allocator)
		return err
	}
	return nil
}

// enter_dotted steps into `key` for a dotted key, creating the table when it's missing.
@(private = "file")
enter_dotted :: proc(p: ^Parser, t: ^Table, key: string, pos: int) -> (sub: ^Table, err: Error) {
	existing, found := t.values[key]
	if !found {
		return add_table(p, t, key, .Dotted)
	}
	is_table: bool
	if sub, is_table = existing.(^Table); !is_table {
		return nil, fail(p, .Not_A_Table, pos)
	}
	kind, mutable := p.kinds[sub]
	if !mutable {
		return nil, fail(p, .Inline_Table_Is_Immutable, pos)
	}
	if kind != .Dotted {
		// Dotted keys can't reopen a table that a header created or defined.
		return nil, fail(p, .Duplicate_Table, pos)
	}
	return sub, nil
}

// enter_header steps into `key` along a table header path, creating an implicit table when it's missing.
@(private = "file")
enter_header :: proc(p: ^Parser, t: ^Table, key: string, pos: int) -> (sub: ^Table, err: Error) {
	existing, found := t.values[key]
	if !found {
		return add_table(p, t, key, .Implicit)
	}
	#partial switch v in existing {
	case ^Table:
		if v in p.kinds {
			return v, nil
		}
		return nil, fail(p, .Inline_Table_Is_Immutable, pos)
	case ^Array:
		if v in p.headers {
			// A path through an array of tables refers to its latest element.
			return v.items[len(v.items) - 1].(^Table), nil
		}
		return nil, fail(p, .Static_Array_Is_Immutable, pos)
	}
	return nil, fail(p, .Not_A_Table, pos)
}

// parse_header reads `[a.b]` or `[[a.b]]` and makes the named table current.
@(private = "file")
parse_header :: proc(p: ^Parser) -> Error {
	p.pos += 1
	is_array := peek(p) == '['
	if is_array {
		p.pos += 1
	}
	skip_whitespace(p)
	key_pos := p.pos
	parts := parse_key(p) or_return
	defer destroy_key(parts, p.allocator)

	if peek(p) != ']' {
		return fail(p, .Unterminated_Table_Header, p.pos)
	}
	p.pos += 1
	if is_array {
		if peek(p) != ']' {
			return fail(p, .Unterminated_Table_Header, p.pos)
		}
		p.pos += 1
	}
	expect_line_end(p) or_return

	// The named table sits one level below the root for each part of the header.
	if len(parts) > MAX_NESTING_DEPTH {
		return fail(p, .Nesting_Too_Deep, key_pos)
	}
	p.depth = len(parts)

	t := p.root
	for part in parts[:len(parts) - 1] {
		t = enter_header(p, t, part, key_pos) or_return
	}
	last := parts[len(parts) - 1]
	existing, found := t.values[last]

	if is_array {
		if !found {
			a := array_make(p.allocator) or_return
			if err := table_set(t, last, a); err != nil {
				array_destroy(a)
				return err
			}
			_, slot, _, err := map_entry(&p.headers, a)
			if err != nil {
				return err
			}
			slot^ = {}
			p.current = add_array_element(p, a) or_return
			return nil
		}
		#partial switch v in existing {
		case ^Array:
			if v in p.headers {
				p.current = add_array_element(p, v) or_return
				return nil
			}
			return fail(p, .Static_Array_Is_Immutable, key_pos)
		case ^Table:
			if v in p.kinds {
				return fail(p, .Duplicate_Table, key_pos)
			}
		}
		return fail(p, .Duplicate_Key, key_pos)
	}

	if !found {
		p.current = add_table(p, t, last, .Explicit) or_return
		return nil
	}
	#partial switch v in existing {
	case ^Table:
		kind, mutable := p.kinds[v]
		if !mutable {
			return fail(p, .Duplicate_Key, key_pos)
		}
		if kind != .Implicit {
			return fail(p, .Duplicate_Table, key_pos)
		}
		p.kinds[v] = .Explicit
		p.current = v
		return nil
	case ^Array:
		if v in p.headers {
			return fail(p, .Duplicate_Table, key_pos)
		}
	}
	return fail(p, .Duplicate_Key, key_pos)
}

@(private = "file")
parse_value :: proc(p: ^Parser) -> (value: Value, err: Error) {
	if at_end(p) {
		return nil, fail(p, .Expected_Value, p.pos)
	}
	rest := p.src[p.pos:]
	switch rest[0] {
	case '"':
		if strings.has_prefix(rest, `"""`) {
			return parse_multiline_basic_string(p)
		}
		return parse_basic_string(p)
	case '\'':
		if strings.has_prefix(rest, `'''`) {
			return parse_multiline_literal_string(p)
		}
		return parse_literal_string(p)
	case '[':
		return parse_array(p)
	case '{':
		return parse_inline_table(p)
	case 't':
		if strings.has_prefix(rest, "true") {
			p.pos += 4
			return true, nil
		}
	case 'f':
		if strings.has_prefix(rest, "false") {
			p.pos += 5
			return false, nil
		}
	case 'i', 'n', '+', '-':
		return parse_number(p)
	case '0' ..= '9':
		if len(rest) >= 5 && is_digit(rest[0]) && is_digit(rest[1]) && is_digit(rest[2]) && is_digit(rest[3]) && rest[4] == '-' {
			return parse_datetime(p)
		}
		if len(rest) >= 3 && is_digit(rest[1]) && rest[2] == ':' {
			return parse_time(p)
		}
		return parse_number(p)
	}
	return nil, fail(p, .Expected_Value, p.pos)
}

@(private = "file")
enter_nesting :: proc(p: ^Parser) -> Error {
	p.depth += 1
	if p.depth > MAX_NESTING_DEPTH {
		return fail(p, .Nesting_Too_Deep, p.pos)
	}
	return nil
}

@(private = "file")
parse_array :: proc(p: ^Parser) -> (value: Value, err: Error) {
	defer p.depth -= 1
	enter_nesting(p) or_return
	p.pos += 1

	a := array_make(p.allocator) or_return
	defer if err != nil {
		array_destroy(a)
	}
	for {
		skip_trivia(p) or_return
		if at_end(p) {
			return nil, fail(p, .Unexpected_Eof, p.pos)
		}
		if p.src[p.pos] == ']' {
			p.pos += 1
			return a, nil
		}

		item := parse_value(p) or_return
		if append_err := array_append(a, item); append_err != nil {
			value_destroy(item, p.allocator)
			return nil, append_err
		}

		skip_trivia(p) or_return
		if at_end(p) {
			return nil, fail(p, .Unexpected_Eof, p.pos)
		}
		switch p.src[p.pos] {
		case ',':
			p.pos += 1
		case ']':
			p.pos += 1
			return a, nil
		case:
			return nil, fail(p, .Expected_Comma_Or_Bracket, p.pos)
		}
	}
}

@(private = "file")
parse_inline_table :: proc(p: ^Parser) -> (value: Value, err: Error) {
	defer p.depth -= 1
	enter_nesting(p) or_return
	p.pos += 1

	t := table_make(p.allocator) or_return
	defer if err != nil {
		table_destroy(t)
	}
	skip_whitespace(p)
	if peek(p) == '}' {
		p.pos += 1
		return t, nil
	}
	for {
		skip_whitespace(p)
		parse_key_value(p, t) or_return
		skip_whitespace(p)
		if at_end(p) {
			return nil, fail(p, .Unexpected_Eof, p.pos)
		}
		switch p.src[p.pos] {
		case ',':
			p.pos += 1
			skip_whitespace(p)
			if peek(p) == '}' {
				return nil, fail(p, .Trailing_Comma_In_Inline_Table, p.pos)
			}
		case '}':
			p.pos += 1
			unmark_inline(p, t)
			return t, nil
		case:
			return nil, fail(p, .Expected_Comma_Or_Brace, p.pos)
		}
	}
}

// parse_escape reads one escape sequence starting at the backslash and appends its text to `buf`.
@(private = "file")
parse_escape :: proc(p: ^Parser, buf: ^[dynamic]byte) -> Error {
	start := p.pos
	p.pos += 1
	if at_end(p) {
		return fail(p, .Invalid_Escape, start)
	}
	c := p.src[p.pos]
	p.pos += 1
	replacement: byte
	switch c {
	case 'b':
		replacement = '\b'
	case 't':
		replacement = '\t'
	case 'n':
		replacement = '\n'
	case 'f':
		replacement = '\f'
	case 'r':
		replacement = '\r'
	case '"':
		replacement = '"'
	case '\\':
		replacement = '\\'
	case 'u', 'U':
		digits := 4 if c == 'u' else 8
		if p.pos + digits > len(p.src) {
			return fail(p, .Invalid_Unicode_Escape, start)
		}
		r: u32
		for h in transmute([]byte)p.src[p.pos:p.pos + digits] {
			d: u32
			switch h {
			case '0' ..= '9':
				d = u32(h - '0')
			case 'a' ..= 'f':
				d = u32(h - 'a' + 10)
			case 'A' ..= 'F':
				d = u32(h - 'A' + 10)
			case:
				return fail(p, .Invalid_Unicode_Escape, start)
			}
			r = r << 4 | d
		}
		if r > utf8.MAX_RUNE || (r >= 0xd800 && r <= 0xdfff) {
			return fail(p, .Invalid_Unicode_Escape, start)
		}
		p.pos += digits
		bytes, n := utf8.encode_rune(rune(r))
		_, err := append(buf, ..bytes[:n])
		return err
	case:
		return fail(p, .Invalid_Escape, start)
	}
	_, err := append(buf, replacement)
	return err
}

// finish_string turns a scratch buffer into a string allocated with the parser's allocator.
@(private = "file")
finish_string :: proc(p: ^Parser, buf: [dynamic]byte) -> (s: string, err: Error) {
	// On error the caller still owns `buf` and frees it, so only free it here on success.
	s = clone_string(string(buf[:]), p.allocator) or_return
	delete(buf)
	return s, nil
}

@(private = "file")
parse_basic_string :: proc(p: ^Parser) -> (s: string, err: Error) {
	start := p.pos
	p.pos += 1
	buf := make([dynamic]byte, p.allocator)
	defer if err != nil {
		delete(buf)
	}
	for {
		if at_end(p) {
			return "", fail(p, .Unterminated_String, start)
		}
		c := p.src[p.pos]
		switch {
		case c == '"':
			p.pos += 1
			return finish_string(p, buf)
		case c == '\\':
			parse_escape(p, &buf) or_return
		case c == '\n' || c == '\r':
			return "", fail(p, .Unterminated_String, start)
		case is_control(c):
			return "", fail(p, .Invalid_Control_Character, p.pos)
		case:
			run := p.pos
			for p.pos < len(p.src) {
				b := p.src[p.pos]
				if b == '"' || b == '\\' || is_control(b) {
					break
				}
				p.pos += 1
			}
			append(&buf, p.src[run:p.pos]) or_return
		}
	}
}

@(private = "file")
parse_literal_string :: proc(p: ^Parser) -> (s: string, err: Error) {
	start := p.pos
	p.pos += 1
	for {
		if at_end(p) {
			return "", fail(p, .Unterminated_String, start)
		}
		c := p.src[p.pos]
		switch {
		case c == '\'':
			p.pos += 1
			return clone_string(p.src[start + 1:p.pos - 1], p.allocator)
		case c == '\n' || c == '\r':
			return "", fail(p, .Unterminated_String, start)
		case is_control(c):
			return "", fail(p, .Invalid_Control_Character, p.pos)
		}
		p.pos += 1
	}
}

// skip_opening_newline drops the newline that may directly follow `"""` or `'''`.
@(private = "file")
skip_opening_newline :: proc(p: ^Parser) {
	if strings.has_prefix(p.src[p.pos:], "\n") {
		p.pos += 1
	} else if strings.has_prefix(p.src[p.pos:], "\r\n") {
		p.pos += 2
	}
}

/*
close_multiline handles a run of quote characters inside a multi-line string.
Up to two quotes may sit right before the closing delimiter, so a run of three
to five closes the string with the extras as content.
*/
@(private = "file")
close_multiline :: proc(p: ^Parser, buf: ^[dynamic]byte, quote: byte) -> (closed: bool, err: Error) {
	n := 0
	for p.pos + n < len(p.src) && p.src[p.pos + n] == quote {
		n += 1
	}
	if n < 3 {
		append(buf, p.src[p.pos:p.pos + n]) or_return
		p.pos += n
		return false, nil
	}
	extra := min(n, 5) - 3
	append(buf, p.src[p.pos:p.pos + extra]) or_return
	p.pos += extra + 3
	return true, nil
}

@(private = "file")
parse_multiline_basic_string :: proc(p: ^Parser) -> (s: string, err: Error) {
	start := p.pos
	p.pos += 3
	skip_opening_newline(p)
	buf := make([dynamic]byte, p.allocator)
	defer if err != nil {
		delete(buf)
	}
	for {
		if at_end(p) {
			return "", fail(p, .Unterminated_String, start)
		}
		c := p.src[p.pos]
		switch {
		case c == '"':
			if close_multiline(p, &buf, '"') or_return {
				return finish_string(p, buf)
			}
		case c == '\\':
			// A backslash that ends a line trims the newline and all whitespace after it.
			j := p.pos + 1
			for j < len(p.src) && (p.src[j] == ' ' || p.src[j] == '\t') {
				j += 1
			}
			rest := p.src[j:]
			if strings.has_prefix(rest, "\n") || strings.has_prefix(rest, "\r\n") {
				p.pos = j
				trim: for p.pos < len(p.src) {
					switch {
					case p.src[p.pos] == ' ', p.src[p.pos] == '\t', p.src[p.pos] == '\n':
						p.pos += 1
					case strings.has_prefix(p.src[p.pos:], "\r\n"):
						p.pos += 2
					case:
						break trim
					}
				}
			} else {
				parse_escape(p, &buf) or_return
			}
		case c == '\n':
			append(&buf, '\n') or_return
			p.pos += 1
		case c == '\r':
			if !strings.has_prefix(p.src[p.pos:], "\r\n") {
				return "", fail(p, .Bare_Carriage_Return, p.pos)
			}
			append(&buf, '\n') or_return
			p.pos += 2
		case is_control(c):
			return "", fail(p, .Invalid_Control_Character, p.pos)
		case:
			run := p.pos
			for p.pos < len(p.src) {
				b := p.src[p.pos]
				if b == '"' || b == '\\' || is_control(b) {
					break
				}
				p.pos += 1
			}
			append(&buf, p.src[run:p.pos]) or_return
		}
	}
}

@(private = "file")
parse_multiline_literal_string :: proc(p: ^Parser) -> (s: string, err: Error) {
	start := p.pos
	p.pos += 3
	skip_opening_newline(p)
	buf := make([dynamic]byte, p.allocator)
	defer if err != nil {
		delete(buf)
	}
	for {
		if at_end(p) {
			return "", fail(p, .Unterminated_String, start)
		}
		c := p.src[p.pos]
		switch {
		case c == '\'':
			if close_multiline(p, &buf, '\'') or_return {
				return finish_string(p, buf)
			}
		case c == '\n':
			append(&buf, '\n') or_return
			p.pos += 1
		case c == '\r':
			if !strings.has_prefix(p.src[p.pos:], "\r\n") {
				return "", fail(p, .Bare_Carriage_Return, p.pos)
			}
			append(&buf, '\n') or_return
			p.pos += 2
		case is_control(c):
			return "", fail(p, .Invalid_Control_Character, p.pos)
		case:
			run := p.pos
			for p.pos < len(p.src) {
				b := p.src[p.pos]
				if b == '\'' || is_control(b) {
					break
				}
				p.pos += 1
			}
			append(&buf, p.src[run:p.pos]) or_return
		}
	}
}

// valid_digits checks a run of digits in `base` with single underscores only between digits.
@(private = "file")
valid_digits :: proc(s: string, base: int) -> bool {
	if len(s) == 0 || s[0] == '_' || s[len(s) - 1] == '_' {
		return false
	}
	prev_underscore := false
	for c in transmute([]byte)s {
		if c == '_' {
			if prev_underscore {
				return false
			}
			prev_underscore = true
			continue
		}
		prev_underscore = false
		if digit_value(c) >= base {
			return false
		}
	}
	return true
}

@(private = "file")
digit_value :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return 99
}

// accumulate converts validated digits to a magnitude, failing when it exceeds `limit`.
@(private = "file")
accumulate :: proc(s: string, base: int, limit: u64) -> (n: u64, ok: bool) {
	for c in transmute([]byte)s {
		if c == '_' {
			continue
		}
		d := u64(digit_value(c))
		if n > (limit - d) / u64(base) {
			return 0, false
		}
		n = n * u64(base) + d
	}
	return n, true
}

@(private = "file")
parse_number :: proc(p: ^Parser) -> (value: Value, err: Error) {
	start := p.pos
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if (is_bare_key_char(c) && c != '-') || c == '.' {
			p.pos += 1
			continue
		}
		if (c == '+' || c == '-') && (p.pos == start || p.src[p.pos - 1] == 'e' || p.src[p.pos - 1] == 'E') {
			p.pos += 1
			continue
		}
		break
	}
	token := p.src[start:p.pos]

	body := token
	negative, signed := false, false
	if len(body) > 0 && (body[0] == '+' || body[0] == '-') {
		signed = true
		negative = body[0] == '-'
		body = body[1:]
	}
	switch body {
	case "inf":
		return math.inf_f64(-1 if negative else 1), nil
	case "nan":
		return math.nan_f64(), nil
	}
	if len(body) == 0 || !is_digit(body[0]) {
		return nil, fail(p, .Expected_Value, start)
	}

	if len(body) > 1 && body[0] == '0' && (body[1] == 'x' || body[1] == 'o' || body[1] == 'b') {
		base := 16 if body[1] == 'x' else 8 if body[1] == 'o' else 2
		digits := body[2:]
		if signed || !valid_digits(digits, base) {
			return nil, fail(p, .Invalid_Integer, start)
		}
		n, ok := accumulate(digits, base, u64(max(i64)))
		if !ok {
			return nil, fail(p, .Integer_Overflow, start)
		}
		return i64(n), nil
	}

	if strings.contains_any(body, ".eE") {
		return parse_float(p, token, body, start)
	}

	if !valid_digits(body, 10) || (len(body) > 1 && body[0] == '0') {
		return nil, fail(p, .Invalid_Integer, start)
	}
	limit := u64(max(i64)) + 1 if negative else u64(max(i64))
	n, ok := accumulate(body, 10, limit)
	if !ok {
		return nil, fail(p, .Integer_Overflow, start)
	}
	if negative {
		return -i64(n), nil
	}
	return i64(n), nil
}

@(private = "file")
parse_float :: proc(p: ^Parser, token, body: string, start: int) -> (value: Value, err: Error) {
	mantissa, exponent := body, ""
	has_exponent := false
	if i := strings.index_any(body, "eE"); i >= 0 {
		mantissa, exponent = body[:i], body[i + 1:]
		has_exponent = true
	}
	whole, fraction := mantissa, ""
	has_fraction := false
	if i := strings.index_byte(mantissa, '.'); i >= 0 {
		whole, fraction = mantissa[:i], mantissa[i + 1:]
		has_fraction = true
	}
	if len(exponent) > 0 && (exponent[0] == '+' || exponent[0] == '-') {
		exponent = exponent[1:]
	}
	valid := valid_digits(whole, 10) && !(len(whole) > 1 && whole[0] == '0')
	valid &&= !has_fraction || valid_digits(fraction, 10)
	valid &&= !has_exponent || valid_digits(exponent, 10)
	if !valid {
		return nil, fail(p, .Invalid_Float, start)
	}

	// Strip underscores into a stack buffer; long literals fall back to the allocator.
	stack: [128]byte
	buf := stack[:]
	if len(token) > len(stack) {
		buf = make([]byte, len(token), p.allocator) or_return
	}
	defer if len(token) > len(stack) {
		delete(buf, p.allocator)
	}
	n := 0
	for c in transmute([]byte)token {
		if c != '_' {
			buf[n] = c
			n += 1
		}
	}
	f, ok := strconv.parse_f64(string(buf[:n]))
	if !ok {
		return nil, fail(p, .Invalid_Float, start)
	}
	return f, nil
}

@(private = "file")
read_two_digits :: proc(s: string, at: int) -> (n: int, ok: bool) {
	if at + 2 > len(s) || !is_digit(s[at]) || !is_digit(s[at + 1]) {
		return 0, false
	}
	return int(s[at] - '0') * 10 + int(s[at + 1] - '0'), true
}

@(private = "file")
days_in_month :: proc(year, month: int) -> int {
	switch month {
	case 2:
		leap := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
		return 29 if leap else 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

@(private = "file")
parse_datetime :: proc(p: ^Parser) -> (value: Value, err: Error) {
	start := p.pos
	s := p.src
	century, c_ok := read_two_digits(s, start)
	year_low, y_ok := read_two_digits(s, start + 2)
	month, m_ok := read_two_digits(s, start + 5)
	day, d_ok := read_two_digits(s, start + 8)
	if !(c_ok && y_ok && m_ok && d_ok) || s[start + 7] != '-' {
		return nil, fail(p, .Invalid_Datetime, start)
	}
	date := Date{century * 100 + year_low, month, day}
	if month < 1 || month > 12 || day < 1 || day > days_in_month(date.year, month) {
		return nil, fail(p, .Invalid_Datetime, start)
	}
	p.pos += 10

	has_time := false
	switch peek(p) {
	case 'T', 't':
		has_time = true
	case ' ':
		// A space separates date and time only when a time follows.
		_, ok := read_two_digits(s, p.pos + 1)
		has_time = ok && p.pos + 3 < len(s) && s[p.pos + 3] == ':'
	case '0' ..= '9':
		return nil, fail(p, .Invalid_Datetime, start)
	}
	if !has_time {
		return date, nil
	}
	p.pos += 1
	time_value := parse_time(p) or_return
	time := time_value.(Time)

	switch peek(p) {
	case 'Z', 'z':
		p.pos += 1
		return Offset_Datetime{date, time, 0}, nil
	case '+', '-':
		sign := -1 if s[p.pos] == '-' else 1
		hours, h_ok := read_two_digits(s, p.pos + 1)
		minutes, min_ok := read_two_digits(s, p.pos + 4)
		if !h_ok || !min_ok || s[p.pos + 3] != ':' || hours > 23 || minutes > 59 {
			return nil, fail(p, .Invalid_Datetime, p.pos)
		}
		p.pos += 6
		if is_digit(peek(p)) {
			return nil, fail(p, .Invalid_Datetime, start)
		}
		return Offset_Datetime{date, time, sign * (hours * 60 + minutes)}, nil
	}
	return Local_Datetime{date, time}, nil
}

@(private = "file")
parse_time :: proc(p: ^Parser) -> (value: Value, err: Error) {
	start := p.pos
	s := p.src
	hour, h_ok := read_two_digits(s, start)
	minute, m_ok := read_two_digits(s, start + 3)
	second, s_ok := read_two_digits(s, start + 6)
	if !(h_ok && m_ok && s_ok) || s[start + 2] != ':' || s[start + 5] != ':' {
		return nil, fail(p, .Invalid_Datetime, start)
	}
	if hour > 23 || minute > 59 || second > 60 {
		return nil, fail(p, .Invalid_Datetime, start)
	}
	p.pos += 8

	nanosecond := 0
	if peek(p) == '.' {
		p.pos += 1
		digits := 0
		for p.pos < len(s) && is_digit(s[p.pos]) {
			if digits < 9 {
				nanosecond = nanosecond * 10 + int(s[p.pos] - '0')
			}
			digits += 1
			p.pos += 1
		}
		if digits == 0 {
			return nil, fail(p, .Invalid_Datetime, start)
		}
		for _ in digits ..< 9 {
			nanosecond *= 10
		}
	} else if is_digit(peek(p)) {
		return nil, fail(p, .Invalid_Datetime, start)
	}
	return Time{hour, minute, second, nanosecond}, nil
}

// find_invalid_utf8 returns the byte offset of the first invalid UTF-8 sequence, or -1.
@(private = "file")
find_invalid_utf8 :: proc(s: string) -> int {
	if utf8.valid_string(s) {
		return -1
	}
	i := 0
	for i < len(s) {
		r, size := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && size <= 1 {
			return i
		}
		i += size
	}
	return len(s)
}

// location_at converts a byte offset into a 1-based line and column.
@(private = "file")
location_at :: proc(s: string, byte_offset: int) -> Location {
	offset := clamp(byte_offset, 0, len(s))
	loc := Location {
		offset = offset,
		line   = 1,
		column = 1,
	}
	for c in transmute([]byte)s[:offset] {
		if c == '\n' {
			loc.line += 1
			loc.column = 1
		} else if c & 0xc0 != 0x80 {
			loc.column += 1
		}
	}
	return loc
}
