# libpdx-argv.M1-002 — implementation notes

**Issue:** #2 — short-flag grammar one-per-hyphen (clustered → reject,
per D3 in `design/tooling/plan.md`).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/parser.pdx`: replaced the M1-001 `parse_argv_maybe_flag`
  short-flag stub (which returned `ERR_UNKNOWN_ARG_FORM` for any byte1
  that wasn't `'-'` or NUL) with a full short-flag handler:
  - `parse_argv_short_flag` — checks byte2. NUL → single-letter short
    flag (route to `parse_argv_store_short_flag`); anything else →
    `parse_argv_short_clustered` → sets `ERR_CLUSTERED_SHORT` (=4).
  - `parse_argv_store_short_flag` — same overflow discipline as the
    long-flag store; `flag_names[k]` = `arg_ptr + 1` (interior pointer
    just past the `-`), `flag_values[k]` = 0 or the consumed
    lookahead arg.
  - Lookahead rule matches the long-flag no-eq path: `argv[i+1]` is
    consumed as the value iff it exists, is non-empty, and does not
    start with `-`.
- `design/architecture.md` §5: clarified `error_arg_index` is now
  written by the parser (not introduced by M1-002 — the slot was
  already declared in M1-001's ParsedArgs; M1-001 just didn't have any
  code path that populated it since the short-flag stub was the only
  error source, and even that stub already wrote error_arg_index).
- `STATUS.md`: M1 closed; M2 unblocked.

## Design decisions

- **Short flags do not participate in the --pdx-schema well-known
  compare.** The upstream flag is spelled long-form only. Any short
  flag whose letter happens to be `-P` (or whatever) is stored as an
  ordinary short flag; the M3 semantic-pipe integration checks
  `emit_schema` (set only by the long-form compare) rather than
  walking flag_names byte-by-byte.
- **`flag_names[k] = arg_ptr + 1` for short flags.** The 1-char string
  followed by the NUL that already lives at `arg_ptr + 2` is a valid
  C-style string; no extra allocation or copy is required. This
  mirrors the long-flag `arg_ptr + 2` interior-pointer trick.
- **Diagnostic recovery for `error_arg_index`.** The clustered-short
  error records the arg index into `ParsedArgs::error_arg_index`. The
  consumer's stderr diagnostic can reconstruct the offending arg text
  with `argv[error_arg_index]` — the parser has not mutated it (the
  in-place NUL write in the long-flag path is only reached for args
  that classify as long flags, and this arg classified as short).

## paideia-as conformance (re-verified)

- Every new `cmp reg, imm` uses `0`, `32`, or `0x2D` — all well within
  the 32-bit immediate constraint.
- Every new byte load is `xor rax, rax; mov_b rax, [ptr]` (or `mov_b
  rax, [ptr + N]` with N ≤ 2).
- No new `test` mnemonic; every zero-check is `cmp reg, 0`.
- `r11` is used only as scratch — LEA temps for the same cross-module
  writes M1-001 used.
- Register plan unchanged from M1-001: r8=i, r9=argv, r10=argc, r11
  scratch, rax byte-load / return, rcx walk cursor / value, rdx arg
  ptr. The short-flag handler reuses rcx/rdx exactly the same way.

## What did not land (queued for M2 and beyond)

- Typed flag arguments (`-o 7d`, `-o=7d`) — M2-001. M1-002 treats every
  short flag's value as an opaque pointer; typed interpretation is
  M2's job.
- The 9-flag standard vocabulary (`--help`, `--version`, `--dry-run`,
  `--json`, `--schema`, `--verbose`, `--quiet`, `--color=`,
  `--no-cap:`) — M2-002. Their short-form aliases (e.g. `-h` for
  `--help`) are also M2.
- Combined short-flag values (`-fvalue` GNU-style) — deferred by D3;
  the one-per-hyphen contract explicitly rejects this shape too. The
  clustered-reject test in M4-001 covers this at test-matrix level.

## Build note

Same as M1-001: libpdx-argv M1 does not ship a local build script.
paideia-as ≥ v0.33 will build both modules once the library reaches
M2 and picks a build entry point.
