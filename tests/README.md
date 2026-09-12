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
  sys_exit_shim.pdx          — SC+ ID 60 trampoline (ENH-007 #14); link-only
```

Test-module IDs (leftmost byte of `TestHarness::last_fail_tag`):

| ID | Module                      | Cases |
|----|-----------------------------|-------|
| 1  | ParseGrammarTests           | 20    |
| 2  | ParseTypedValuesTests       | 24    |
| 3  | ParseTypedArgsTests         | 5     |
| 4  | (reserved: parse_positional_ext) | — |
| 5  | ParseStdVocabTests          | 2     |
| 6  | ParseSchemaRecordTests      | 10    |
| 7  | HelpBackendTests            | 4     |
| 8  | SchemaEmitTests             | 5     |
| 9  | MultiContext                | 3     |

**Total M4-001 cases:** 69 (2 added by `libpdx-argv.ENH-002`, 2 more by
`libpdx-argv.ENH-001`, 3 more by `libpdx-argv.ENH-004`, 1 more by
`libpdx-argv.ENH-008`, 7 more by `libpdx-argv.ENH-009`, 4 more by
`libpdx-argv.ENH-010`, 3 more by `libpdx-argv.ENH-006`).

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

### Strict mode (parse_grammar.pdx, `libpdx-argv.ENH-004`)

| Case | Fixture argv | Expected | Notes |
|-----:|--------------|:--------:|-------|
| 13 | `--nosuchflag foo` (strict unset) | OK, flags=1, pos=1 | permissive default unchanged |
| 14 | `--nosuchflag foo` (strict=1) | ERR_UNKNOWN_FLAG (12), arg_index=0 | long-flag path |
| 15 | `-z` (strict=1) | ERR_UNKNOWN_FLAG (12), arg_index=0 | short-flag path |

### Duplicate-flag policy (parse_grammar.pdx, `libpdx-argv.ENH-008`)

| Case | Fixture argv | Expected | Notes |
|-----:|--------------|:--------:|-------|
| 16 | `--color=auto --color=never` | flags=2; `find_flag_by_id`→auto (first-wins, unchanged); `find_last_flag_by_id`→never; `count_flag_by_id`=2 | new duplicate-flag accessors |

### Per-registration arity policy (parse_grammar.pdx, `libpdx-argv.ENH-010`)

| Case | Fixture argv | Expected | Notes |
|-----:|--------------|:--------:|-------|
| 17 | `--color file.txt` | ERR_MISSING_VALUE (6), arg_index=0 | lookahead rejected (register_sep) |
| 18 | `--color=auto file.txt` | OK, flags=1, pos=1 | inline `=` unaffected |
| 19 | `--no-cap --dry-run /tmp/x` | ERR_MISSING_VALUE (6), arg_index=0 | lookahead rejected |
| 20 | `--no-cap:KIND_TTY --dry-run /tmp/x` | OK, flags=2, pos=1 | inline `:` unaffected |

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
| 18 | `parse_int_u64("18446744073709551615")` | (1, u64::MAX) — `libpdx-argv.ENH-009` exact boundary |
| 19 | `parse_int_u64("18446744073709551616")` | (0, —) — ENH-009 one past MAX |
| 20 | `parse_size("18446744073709551616")` | (0, —) — ENH-009 mantissa-only overflow |
| 21 | `parse_size("17179869184g")` | (0, —) — ENH-009 shift-overflow (mantissa=2^34) |
| 22 | `parse_size("17179869183g")` | (1, (2^34-1)<<30) — ENH-009 shift boundary |
| 23 | `parse_timespan("213503982334602d")` | (0, —) — ENH-009 multiplier overflow |
| 24 | `parse_timespan("213503982334601d")` | (1, 18446744073709526400) — ENH-009 multiplier boundary |
| 25 | `parse_int_u64_ranged("32", 1, 64)` | (1, 32) — `libpdx-argv.ENH-018` in-range; error_code stays 0 |
| 26 | `parse_int_u64_ranged("0", 1, 64)` | (0, —) — ENH-018 below-min; error_code = ERR_INT_RANGE (14) |
| 27 | `parse_int_u64_ranged("65", 1, 64)` | (0, —) — ENH-018 above-max; error_code = ERR_INT_RANGE |
| 28 | `parse_int_u64_ranged("18446744073709551615", 1, 64)` | (0, —) — ENH-018 upper cap, not wrap; ERR_INT_RANGE |
| 29 | `parse_int_u64_ranged("0", 0, 0)` | (1, 0) — ENH-018 sentinel: (min=0, max=0) → range OFF |

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
| 9 | name_off == record_len (65) | ERR_SCHEMA_BAD_OFFSET (10) | ENH-001: off < record_len gate, arg_index=0 |
| 10 | name string with no NUL before record end | ERR_SCHEMA_UNTERMINATED (11) | ENH-001: bounded NUL scan, arg_index=0 |

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

`smoke_driver.pdx` exposes `_start` and calls `SysExit::exit(status)`
after packing its tally as `(pass_count << 16) | fail_count`. The
`SysExit::exit` symbol is supplied by `tests/sys_exit_shim.pdx` —
a two-instruction SC+ ID 60 trampoline landed by
`libpdx-argv.ENH-007` (Closes #14). Both paideia-os user-space and
Linux dispatch sys_exit at syscall 60 with `rdi = status`, so the
linked smoke ELF is host-runnable directly — no QEMU required.

Invoke the runner:

```
bash tools/run-tests.sh
```

The runner:

1. Assembles every `src/*.pdx` and `tests/*.pdx` via paideia-as
   (resolved through `$PAIDEIA_AS`, sibling paideia-os checkout, or
   `$PATH` — same discipline as `tools/build.sh`).
2. Links every emitted object into `build-out/pdxargv_smoke.elf`
   via `ld -T tools/tests-link.ld` (mirrors mkfs.pdxfs's per-tool
   linker script; ENTRY(`_start`), text at 0x00400000, data at
   0x00600000, .bss contiguous with .data).
3. Execs the ELF; a `python3` waitid helper recovers the full
   32-bit `si_status` word (the child's raw exit-code int, which
   shell `$?` clamps to the low 8 bits) and decodes both
   `pass_count` (bits 16..31) and `fail_count` (bits 0..15). If
   python3 is missing, the runner falls back to `$?` and reports
   `fail_count` only.
4. Prints `PDXARGV SMOKE OK` on all-green (`fail_count == 0`,
   `pass_count > 0`) or `PDXARGV SMOKE FAIL` otherwise.

Wrapper exit codes:

| code | meaning |
|-----:|---------|
| 0    | smoke ran clean (`PDXARGV SMOKE OK`) |
| 1    | paideia-as build failed |
| 2    | ld link stage failed (see `build-out/link.log`) |
| 3    | smoke ran but `fail_count > 0` (`PDXARGV SMOKE FAIL`) |
| 4    | smoke killed by a signal (segfault etc.) |
| 5    | prerequisite missing (`paideia-as`, `ld`) |

Use `bash tools/run-tests.sh --no-run` to stop after the link stage
(useful when triaging the link-line composition without side effects).

### Known link-stage hazard

Every test module currently exports its `run_case1`, `run_case2`, ...
functions as bare flat linker symbols. This is by design in
paideia-as: the elaborator flattens `Module::fn` path references to
the last segment (see paideia-as
`parse_stmt::try_extract_symbol_name`, issue #1319). Because six of
the seven test modules define `run_case1`, `ld -z defs` (the default,
correctly kept by this runner) will refuse the link with
`multiple definition of run_case1`.

The runner surfaces this as exit code 2 with a categorised
diagnostic pointing at the paideia-as gap. **Resolutions** — either
land Module::fn symbol mangling in paideia-as (preferred; benefits
every satellite repo) or rename in-repo to
`<module>_<case>` shape (e.g. `parse_grammar_run_case1`) at the cost
of touching every test file. Do NOT paper over with
`--allow-multiple-definition`: silent first-wins resolution would let
each `run_case1` run only once and the smoke would falsely report
green.

### Pre-1.1 provenance

Every "smoke passes" reference in the pre-ENH-007 wave of documents
(STATUS.md's milestone rollup, tests/README.md's `M4-001` coverage
matrix, design/architecture.md §11.4) was actually a claim that each
`.pdx` file assembled cleanly — the `.pdx` files never reached a
linked ELF and the driver never executed. See STATUS.md
§"Runnable smoke wiring" for the plainly-stated provenance.

## Non-goals at M4-001

- No property-based / fuzz driver — deferred to M5+ (a fuzz harness
  needs the pkg CLI wired first).
- No `--help` output byte-diff against a golden .pdxdoc render — that
  needs `doc.M2` runnable, which is a downstream tool. The M4 test
  here verifies the argv-synthesis contract, which is what libpdx-argv
  can guarantee without doc being present.
- No concurrent multi-parse across threads — paideia-os is
  single-threaded so the coexistence issue that motivated
  `ParsedArgsCtx` (see `libpdx-argv.ENH-006`, module id 9 above)
  is sequential, not concurrent. The `MultiContext` module
  covers the sequential-coexistence fingerprint (two contexts,
  two `parse_argv_ctx` calls, no cross-talk); a future ENH may
  add a concurrent-parse test once a thread substrate exists.
