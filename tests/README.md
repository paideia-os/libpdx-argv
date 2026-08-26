# tests/

Parse-correctness matrix + smoke fixtures for libpdx-argv.

Landed by `libpdx-argv.M4-001` per `design/tooling/r49-r50-plan.md`
§5.12 (paideia-os).

## Layout

```
tests/
  harness.pdx                — pass/fail tally + full_reset helper
  parse_grammar.pdx          — long/short/positional/mixed grammar (id 1)
  parse_typed_values.pdx     — Typed::parse_int_u64/size/timespan (id 2)
  parse_typed_args.pdx       — typed flag arg consumption / diagnostic (id 3)
  parse_std_vocab.pdx        — I3 9-flag standard vocabulary (id 5)
  parse_schema_record.pdx    — SchemaInvoke wire-form matrix (id 6)
  help_backend.pdx           — HelpBackend::fill_doc_argv round-trip (id 7)
  schema_emit.pdx            — SchemaEmit register/get/reset (id 8)
  smoke_driver.pdx           — _start; runs every case, sys_exit(pass<<16|fail)
```

Test-module IDs (leftmost byte of `TestHarness::last_fail_tag`):

| ID | Module                      | Cases |
|----|-----------------------------|-------|
| 1  | ParseGrammarTests           | 12    |
| 2  | ParseTypedValuesTests       | 17    |
| 3  | ParseTypedArgsTests         | 5     |
| 4  | (reserved: parse_positional_ext) | — |
| 5  | ParseStdVocabTests          | 2     |
| 6  | ParseSchemaRecordTests      | 8     |
| 7  | HelpBackendTests            | 3     |
| 8  | SchemaEmitTests             | 5     |
| 9  | (reserved: parse_mixed_ext) | —     |

**Total M4-001 cases:** 52 (2 added by `libpdx-argv.ENH-002`).

`last_fail_tag` encoding: `(module_id << 32) | case_number`.
`case_number` is the last hex digit of the module's `run_caseN` name;
one-based within the module.

## Coverage matrix (M4-001 scope)

Per the M4 line in `design/tooling/r49-r50-plan.md` §5.12:

> Parse-correctness matrix (long, short, typed, positional, mixed),
> clustered-short-flag rejection (`-la` → error, per D3), typed-arg-
> parse-error diagnostics, `--help` render round-trip via doc.

### Long-flag grammar (parse_grammar.pdx)

| Case | Fixture argv | Expected error | Notes |
|-----:|--------------|:--------------:|-------|
| 1 | `--help` | OK | boolean; StdVocab id=1 |
| 2 | `--color=auto` | OK | `=` separator; ENUM value stored |
| 3 | `--no-cap:KIND_TTY` | OK | `:` separator (M2-003 universal) |
| 4 | `--json foo` | OK | BOOL flag does NOT consume `foo` (cat-M1 fix) |
| 8 | `--=foo` | ERR_LONG_MISSING_NAME (5) | empty name before `=` |
| 9 | `--:foo` | ERR_LONG_MISSING_NAME (5) | empty name before `:` |
| 11 | `--pdx-schema` | OK | sets emit_schema=1 alongside flag store |

### Short-flag grammar (parse_grammar.pdx)

| Case | Fixture argv | Expected error | Notes |
|-----:|--------------|:--------------:|-------|
| 6 | `-la` | ERR_CLUSTERED_SHORT (4) | D3 one-per-hyphen rejection |
| 7 | `-n` (BOOL) | OK | single-letter accepted |
| 10 | `-` (bare) | OK | positional (stdin convention) |

### Positional + sentinel (parse_grammar.pdx)

| Case | Fixture | Expected | Notes |
|-----:|---------|:--------:|-------|
| 5 | `-- --foo bar` | ddash_seen=1, pos=2 | sentinel routes all subsequent to pos |
| 12 | `--verbose foo --quiet bar` | flags=2, pos=2 | mixed interleave, order-preserving |

### Typed value parsers (parse_typed_values.pdx)

| Case | Function + input | Expected (ok, val) |
|-----:|------------------|:------------------:|
| 1 | `parse_int_u64("0")` | (1, 0) |
| 2 | `parse_int_u64("42")` | (1, 42) |
| 3 | `parse_int_u64("")` | (0, —) |
| 4 | `parse_int_u64("1a")` | (0, —) |
| 5 | `parse_size("0")` | (1, 0) |
| 6 | `parse_size("1k")` | (1, 1024) |
| 7 | `parse_size("1K")` | (1, 1024) |
| 8 | `parse_size("2m")` | (1, 2097152) |
| 9 | `parse_size("3g")` | (1, 0xC0000000) |
| 10 | `parse_size("1kb")` | (0, —) — M2 rejects multi-char |
| 11 | `parse_size("k")` | (0, —) — mantissa required |
| 12 | `parse_timespan("60")` | (1, 60) |
| 13 | `parse_timespan("1s")` | (1, 1) |
| 14 | `parse_timespan("2m")` | (1, 120) |
| 15 | `parse_timespan("3h")` | (1, 10800) |
| 16 | `parse_timespan("7d")` | (1, 604800) |
| 17 | `parse_timespan("1w")` | (0, —) — 'w' unsupported at M2 |

### Typed arg consumption + diagnostics (parse_typed_args.pdx)

| Case | Fixture | Expected | Notes |
|-----:|---------|:--------:|-------|
| 1 | `--older-than 7d` (TIMESPAN) | OK, value='7d', roundtrip 604800 |
| 2 | `--older-than` | ERR_MISSING_VALUE (6) | no lookahead available |
| 3 | `--older-than=7d` | OK, value='7d' | inline `=` skips lookahead |
| 4 | `-n 5` (INT id=101) | OK, roundtrip 5 | typed short consumes |
| 5 | `-n` | ERR_MISSING_VALUE (6) | typed short at EOL |

### I3 standard vocabulary (parse_std_vocab.pdx)

- `run_all_9`: parse all 9 std flags in one argv; verify flag_count=9,
  find_flag_by_id returns non-32 for ids 1..9.
- `run_ids_unique`: FlagSpec::lookup on each of the 9 std names returns
  the expected id.

### SchemaInvoke wire form (parse_schema_record.pdx)

| Case | Fixture | Expected error | Notes |
|-----:|---------|:--------------:|-------|
| 1 | 65-B valid record | OK | 1 flag + 1 pos |
| 2 | bad magic ('X' at [0]) | ERR_SCHEMA_BAD_MAGIC (7) |  |
| 3 | version=99 | ERR_SCHEMA_UNSUPPORTED_VERSION (8) |  |
| 4 | record_len=16 (< 32) | ERR_SCHEMA_BAD_LAYOUT (9) | header-size gate |
| 5 | flag_count=33 (> 32) | ERR_SCHEMA_BAD_LAYOUT (9) | count-cap gate |
| 6 | body-fits fail | ERR_SCHEMA_BAD_LAYOUT (9) | supplied len < required |
| 7 | flag_count=0xFFFFFFFFFFFFFFFF | ERR_SCHEMA_BAD_LAYOUT (9) | ENH-002: unsigned count-cap gate |
| 8 | record_len=0x8000000000000001, empty body | OK | ENH-002: unsigned header-size gate must not false-reject |

### `--help` round-trip (help_backend.pdx)

- `case1`: `DOC_TOOL_NAME` bytes are `{'d','o','c',0}`.
- `case2`: `fill_doc_argv` writes `argv[0] = &DOC_TOOL_NAME` and
  `argv[1] = tool_name_ptr`.
- `case3`: `argv[0]` byte-for-byte stable across two calls (shell
  audit-record join contract).

### SchemaEmit table (schema_emit.pdx)

- `case1`: empty-after-reset invariant.
- `case2`: register 2 → get_name(0/1) returns stored ptrs.
- `case3`: SCHEMA_MAX=8 clamp (9th registration silently drops).
- `case4`: `get_name(idx >= count)` returns 0.
- `case5`: `reset` re-zeros count, forgets prior registrations.

## Running the smoke

`smoke_driver.pdx` exposes `_start` and expects a `SysExit::exit`
symbol to be linked in from a smoke-binary wiring layer (analogous to
`src/user/syscall_shim.pdx` in paideia-os — a per-target module that
converts the `exit(u64)` call into the target's actual sys_exit
syscall). The exit code is packed as `(pass_count << 16) | fail_count`;
a zero low-16 means every case passed.

Once the pkg (§5.11) M4 wiring lands, a shell test wrapper
(analogous to `tools/verify-user-*.sh` in paideia-os) will:

1. Assemble tests/*.pdx + src/*.pdx into `pdxargv_smoke.elf`.
2. Boot the smoke ELF under QEMU or the userspace loader stub.
3. Read the exit code; report `PDXARGV SMOKE OK` on 0-fail or
   `PDXARGV SMOKE FAIL` on non-zero with the packed tally.

The M4-001 deliverable is the tests themselves + the driver shape;
the wrapper lands with pkg.M4 per the M4 dependency chain (`libpdx-
argv.M5-001 dual-signed release + .pdxdoc + mirror push` in turn
depends on pkg.M4 per §5.12).

## Non-goals at M4-001

- No property-based / fuzz driver — deferred to M5+ (a fuzz harness
  needs the pkg CLI wired first).
- No `--help` output byte-diff against a golden .pdxdoc render — that
  needs `doc.M2` runnable, which is a downstream tool. The M4 test
  here verifies the argv-synthesis contract, which is what libpdx-argv
  can guarantee without doc being present.
- No concurrent multi-parse — M2/M3 ParsedArgs is singleton-scoped;
  the caller-owned `ParsedArgs*` variant is a post-M5 concern.
