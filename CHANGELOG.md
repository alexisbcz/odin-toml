# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `parse` reads a TOML 1.0 document into a tree of `Value` nodes and returns a `Parse_Error` with a line and column `Location` for malformed input.
- Support for every TOML 1.0 value: all four string kinds, decimal, hex, octal and binary integers, floats including `inf` and `nan`, booleans, offset and local date-times, local dates and local times, arrays and inline tables.
- Enforcement of the table rules: duplicate keys, redefined tables, dotted keys reaching into header tables, and changes to inline tables or static arrays.
- `encode` and `write` turn a tree back into a TOML document that parses to an equal tree.
- `table_make`, `table_set`, `table_get`, `array_make` and `array_append` for building trees in code, with `table_destroy`, `array_destroy` and `value_destroy` to free them.
- Typed getters `get`, `get_string`, `get_int`, `get_float`, `get_bool`, `get_table` and `get_array` that follow a key path.
- `value_equal` for comparing trees regardless of key order.
- Examples `basic` and `build`.

[Unreleased]: https://github.com/alexisbcz/odin-toml/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-toml/releases/tag/v0.1.0
