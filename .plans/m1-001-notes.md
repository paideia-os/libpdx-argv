# libpdx-argv.M1-001 — implementation notes

**Issue:** #1 — scaffold + ParsedArgs struct + long-flag grammar
(`--foo bar` / `--foo=bar`).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `caps.decl` — libpdx-argv requires no caps of its own (pure userspace
  library); declares the `PdxArgvParsed@0.1` output schema for the M3
  semantic-pipe integration.
- `design/architecture.md` — full internal spec: ParsedArgs record shape,
  storage model (singleton `.bss`), state machine, short-flag rejection
  contract (spec only in M1-001; code in M1-002), paideia-as encoding
  conformance, and explicit non-goals for M1.
- `src/parsed_args.pdx` — `ParsedArgs` module: error-code constants,
  slot-count constants, singleton `.bss` storage, `reset()` entry point.
- `src/parser.pdx` — `Parser` module: `parse_argv(argv, argc) → u64`
  entry point with long-flag grammar (`--foo`, `--foo=bar`, `--foo bar`
  lookahead), positional handling, and well-known `--pdx-schema`
  detection (sets `emit_schema=1` in addition to normal flag storage).
- `tests/README.md` — pointer to `libpdx-argv.M4-001` for the actual
  test matrix.

## Design decisions

- **Singleton `.bss` storage.** Follows the `Tokenizer::argv_buf` /
  `Dispatch::builtin_names` precedent in `src/user/*.pdx` (paideia-os).
  Zero heap, one parse per process is enough for R49/R50 tools. M4-001
  adds a caller-owned struct variant so tests can build many contexts.
- **In-place null-termination for `--foo=bar`.** Mirrors the tokenizer's
  in-place NUL write on whitespace runs. Safe because the caller owns
  argv and libpdx-argv runs synchronously in the caller's process.
- **Well-known `--pdx-schema` inline compare.** libpdx-argv predates any
  strcmp helper; the byte-by-byte compare against `"pdx-schema\0"` is
  ~30 lines of raw compare-and-branch. When M2 lands the 9-flag standard
  vocabulary the same pattern extends to `--help`, `--version`, etc.,
  and softarch will factor a `well_known_flag_id(name) → i64` helper.
- **Short-flag arm is a stub.** `parse_argv_maybe_flag` returns
  `ERR_UNKNOWN_ARG_FORM` when byte1 is neither `'-'` nor NUL. M1-002
  replaces this branch with the one-per-hyphen handler + clustered
  rejection. No test exists for the M1-001 short-flag path — it is a
  transient shape only.

## paideia-as conformance

- Module names PascalCase basename (`ParsedArgs`, `Parser`) with no
  directory prefix.
- No `test` mnemonic anywhere; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (max value seen:
  `0x7F` — the ASCII range for character comparisons).
- `r11` used only as scratch (LEA temps for cross-module references).
  Never live across a call or expected to survive.
- Byte loads always preceded by `xor rax, rax` per the paideia-as #1248
  mitigation pattern.

## Cross-module linkage

`src/parser.pdx` references `flag_names`, `flag_values`, `flag_count`,
`pos_ptrs`, `pos_count`, `error_code`, `error_arg_index`, `emit_schema`
by unqualified linker name — the paideia-as toolchain resolves these
across compilation units per the `Tokenizer::argc` reference pattern in
`src/user/dispatch.pdx` (paideia-os).

## What did not land (queued for M1-002 and beyond)

- Short-flag one-per-hyphen (`-f` accepted, `-la` rejected with
  `ERR_CLUSTERED_SHORT`) — M1-002.
- Typed flag arguments (`--older-than 7d`) — M2-001.
- 9-flag standard vocabulary — M2-002.
- Positional-argument list edge cases (`--` sentinel, filename-with-dash)
  — M2-003.
- Semantic-pipe emission of the parsed schema record on `--pdx-schema`
  — M3-001.
- `--help` back-end integration with `doc` — M3-002.

## Build note

libpdx-argv M1 has no local build script yet. paideia-as ≥ v0.33 (for the
`mov_b` narrow-load mnemonic + the `@align` attribute) will build both
modules once main invokes `paideia-as build src/parsed_args.pdx
src/parser.pdx -o build/libpdx-argv.pdxlib` — the exact invocation is a
libpdx-argv.M2 concern, not M1.
