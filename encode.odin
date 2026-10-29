package toml

import "core:io"
import "core:math"
import "core:strconv"
import "core:strings"

/*
encode writes `t` as a TOML document.

Each table writes its plain key/value pairs first, then its subtables as
`[header]` sections and its arrays of tables as `[[header]]` sections. An
array whose items are all tables becomes an array of tables; any other array,
and every table inside one, is written inline. Keys keep their order within
each group. Parsing the output gives a tree that value_equal reports as equal
to `t`.

Inputs:
- t: the root table.
- allocator: allocates the result.

Returns:
- result: the document, owned by the caller; free it with `delete(result, allocator)`.
- err: `Encode_Error.Nil_Value` when the tree holds a nil Value,
  `Encode_Error.Nesting_Too_Deep` for trees deeper than MAX_NESTING_DEPTH, or
  an allocator error.
*/
encode :: proc(t: ^Table, allocator := context.allocator) -> (result: string, err: Error) {
	b := strings.builder_make_none(allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}
	write(strings.to_writer(&b), t) or_return
	return strings.to_string(b), nil
}

/*
write encodes `t` to `w` with the same layout as encode. It allocates nothing.

Returns nil, an Encode_Error, or the first io.Error from `w`. On error, `w`
may already hold part of the document.
*/
write :: proc(w: io.Writer, t: ^Table) -> Error {
	if t == nil {
		return .Nil_Value
	}
	e := Encoder {
		w = w,
	}
	return write_table_body(&e, t)
}

@(private = "file")
Encoder :: struct {
	w:         io.Writer,
	path:      [MAX_NESTING_DEPTH]string,
	path_len:  int,
	depth:     int,
	wrote_any: bool,
}

@(private = "file")
put :: proc(e: ^Encoder, s: string) -> Error {
	_, err := io.write_string(e.w, s)
	return err
}

@(private = "file")
put_byte :: proc(e: ^Encoder, c: byte) -> Error {
	return io.write_byte(e.w, c)
}

// is_section reports whether a value gets its own `[header]` or `[[header]]` instead of a key/value line.
@(private = "file")
is_section :: proc(v: Value) -> bool {
	#partial switch x in v {
	case ^Table:
		return x != nil
	case ^Array:
		return is_table_array(x)
	}
	return false
}

@(private = "file")
is_table_array :: proc(a: ^Array) -> bool {
	if a == nil || len(a.items) == 0 {
		return false
	}
	for item in a.items {
		t, is_table := item.(^Table)
		if !is_table || t == nil {
			return false
		}
	}
	return true
}

@(private = "file")
write_table_body :: proc(e: ^Encoder, t: ^Table) -> Error {
	e.depth += 1
	defer e.depth -= 1
	if e.depth > MAX_NESTING_DEPTH {
		return Encode_Error.Nesting_Too_Deep
	}

	for key in t.keys {
		value := t.values[key]
		if is_section(value) {
			continue
		}
		write_key(e, key) or_return
		put(e, " = ") or_return
		write_inline(e, value) or_return
		put_byte(e, '\n') or_return
		e.wrote_any = true
	}

	for key in t.keys {
		#partial switch v in t.values[key] {
		case ^Table:
			if v == nil {
				continue
			}
			e.path[e.path_len] = key
			e.path_len += 1
			if needs_header(v) {
				write_header(e, false) or_return
			}
			write_table_body(e, v) or_return
			e.path_len -= 1
		case ^Array:
			if !is_table_array(v) {
				continue
			}
			e.path[e.path_len] = key
			e.path_len += 1
			for item in v.items {
				write_header(e, true) or_return
				write_table_body(e, item.(^Table)) or_return
			}
			e.path_len -= 1
		}
	}
	return nil
}

// needs_header is false for a table that holds only sections, whose own headers define it implicitly.
@(private = "file")
needs_header :: proc(t: ^Table) -> bool {
	if len(t.keys) == 0 {
		return true
	}
	for key in t.keys {
		if !is_section(t.values[key]) {
			return true
		}
	}
	return false
}

@(private = "file")
write_header :: proc(e: ^Encoder, array: bool) -> Error {
	if e.wrote_any {
		put_byte(e, '\n') or_return
	}
	put(e, "[[" if array else "[") or_return
	for key, i in e.path[:e.path_len] {
		if i > 0 {
			put_byte(e, '.') or_return
		}
		write_key(e, key) or_return
	}
	put(e, "]]\n" if array else "]\n") or_return
	e.wrote_any = true
	return nil
}

@(private = "file")
write_key :: proc(e: ^Encoder, key: string) -> Error {
	bare := len(key) > 0
	for c in transmute([]byte)key {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '-':
			continue
		}
		bare = false
		break
	}
	if bare {
		return put(e, key)
	}
	return write_string_literal(e, key)
}

@(private = "file")
write_string_literal :: proc(e: ^Encoder, s: string) -> Error {
	hex := "0123456789ABCDEF"
	put_byte(e, '"') or_return
	run := 0
	for i in 0 ..< len(s) {
		c := s[i]
		escape: string
		switch c {
		case '"':
			escape = `\"`
		case '\\':
			escape = `\\`
		case '\b':
			escape = `\b`
		case '\t':
			escape = `\t`
		case '\n':
			escape = `\n`
		case '\f':
			escape = `\f`
		case '\r':
			escape = `\r`
		case 0x00 ..= 0x1f, 0x7f:
			escape = "control"
		case:
			continue
		}
		put(e, s[run:i]) or_return
		run = i + 1
		if escape == "control" {
			put(e, `\u00`) or_return
			put_byte(e, hex[c >> 4]) or_return
			put_byte(e, hex[c & 0xf]) or_return
		} else {
			put(e, escape) or_return
		}
	}
	put(e, s[run:]) or_return
	return put_byte(e, '"')
}

@(private = "file")
write_inline :: proc(e: ^Encoder, value: Value) -> Error {
	switch v in value {
	case nil:
		return .Nil_Value
	case string:
		return write_string_literal(e, v)
	case i64:
		buf: [32]byte
		return put(e, strconv.write_int(buf[:], v, 10))
	case f64:
		return write_float(e, v)
	case bool:
		return put(e, "true" if v else "false")
	case Offset_Datetime:
		write_date(e, v.date) or_return
		put_byte(e, 'T') or_return
		write_time(e, v.time) or_return
		return write_offset(e, v.offset_minutes)
	case Local_Datetime:
		write_date(e, v.date) or_return
		put_byte(e, 'T') or_return
		return write_time(e, v.time)
	case Date:
		return write_date(e, v)
	case Time:
		return write_time(e, v)
	case ^Array:
		if v == nil {
			return .Nil_Value
		}
		e.depth += 1
		defer e.depth -= 1
		if e.depth > MAX_NESTING_DEPTH {
			return Encode_Error.Nesting_Too_Deep
		}
		put_byte(e, '[') or_return
		for item, i in v.items {
			if i > 0 {
				put(e, ", ") or_return
			}
			write_inline(e, item) or_return
		}
		return put_byte(e, ']')
	case ^Table:
		if v == nil {
			return .Nil_Value
		}
		e.depth += 1
		defer e.depth -= 1
		if e.depth > MAX_NESTING_DEPTH {
			return Encode_Error.Nesting_Too_Deep
		}
		if len(v.keys) == 0 {
			return put(e, "{}")
		}
		put(e, "{ ") or_return
		for key, i in v.keys {
			if i > 0 {
				put(e, ", ") or_return
			}
			write_key(e, key) or_return
			put(e, " = ") or_return
			write_inline(e, v.values[key]) or_return
		}
		return put(e, " }")
	}
	return nil
}

@(private = "file")
write_float :: proc(e: ^Encoder, f: f64) -> Error {
	switch {
	case math.is_nan(f):
		return put(e, "nan")
	case math.is_inf(f, 1):
		return put(e, "inf")
	case math.is_inf(f, -1):
		return put(e, "-inf")
	}
	buf: [64]byte
	s := strconv.write_float(buf[:], f, 'g', -1, 64)
	s = strings.trim_prefix(s, "+")
	put(e, s) or_return
	if !strings.contains_any(s, ".e") {
		// TOML needs a fraction or exponent to tell a float from an integer.
		return put(e, ".0")
	}
	return nil
}

@(private = "file")
write_padded :: proc(e: ^Encoder, n: int, width: int) -> Error {
	buf: [20]byte
	i := len(buf)
	v := max(n, 0)
	for {
		i -= 1
		buf[i] = byte('0' + v % 10)
		v /= 10
		if v == 0 && len(buf) - i >= width {
			break
		}
	}
	return put(e, string(buf[i:]))
}

@(private = "file")
write_date :: proc(e: ^Encoder, d: Date) -> Error {
	write_padded(e, d.year, 4) or_return
	put_byte(e, '-') or_return
	write_padded(e, d.month, 2) or_return
	put_byte(e, '-') or_return
	return write_padded(e, d.day, 2)
}

@(private = "file")
write_time :: proc(e: ^Encoder, t: Time) -> Error {
	write_padded(e, t.hour, 2) or_return
	put_byte(e, ':') or_return
	write_padded(e, t.minute, 2) or_return
	put_byte(e, ':') or_return
	write_padded(e, t.second, 2) or_return
	if t.nanosecond <= 0 {
		return nil
	}
	digits: [9]byte
	n := t.nanosecond % 1_000_000_000
	for i := 8; i >= 0; i -= 1 {
		digits[i] = byte('0' + n % 10)
		n /= 10
	}
	end := 9
	for end > 1 && digits[end - 1] == '0' {
		end -= 1
	}
	put_byte(e, '.') or_return
	return put(e, string(digits[:end]))
}

@(private = "file")
write_offset :: proc(e: ^Encoder, minutes: int) -> Error {
	if minutes == 0 {
		return put_byte(e, 'Z')
	}
	put_byte(e, '-' if minutes < 0 else '+') or_return
	m := abs(minutes)
	write_padded(e, m / 60, 2) or_return
	put_byte(e, ':') or_return
	return write_padded(e, m % 60, 2)
}
