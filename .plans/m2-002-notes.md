# libpdx-argv.M2-002 — implementation notes

**Issue:** #4 — 9-flag standard vocabulary from I3
(`--help --version --dry-run --json --schema --verbose --quiet
--color= --no-cap:`).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os)
and `design/tooling/plan.md` I3 (paideia-os).

## What landed

- `src/std_vocab.pdx` — new `StdVocab` module. Contains:
  - Nine `STD_ID_*` u64 constants (1..9). Reserved range; tools
    start their own IDs at 100.
  - Nine `STD_NAME_*` NUL-terminated `.rodata` strings; byte
    length exactly `strlen + 1` so `FlagSpec::lookup`'s inline
    strcmp finds the terminator.
  - `StdVocab::register_all()` — one-shot init: nine
    `FlagSpec::register` calls that install all standard flags.
    Non-leaf; 1-push (rbx, unused, for stack alignment).
- `src/parsed_args.pdx` — added `flag_ids : [u64; 32]` (populated
  by the parser via `FlagSpec::lookup`) + `find_flag_by_id`
  helper. Consumer usage:
  ```
  let k = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
  if k != 32 { render_help(); exit(0) }
  ```
- `src/parser.pdx` — every long-flag and short-flag store now
  writes `flag_ids[k]` and `flag_kinds[k]` alongside the raw
  name/value pointers. See M2-001 for the parser refactor
  details; M2-002 is the "write the two new slots" tangent on
  top of that.

## Design decisions

- **9 flags, exactly the I3 spelling.** No aliases, no
  case-insensitive matches, no short forms. The plan text is
  authoritative — `--help` is `--help` and nothing else. Consumers
  that want a `-h` short form register it explicitly against
  `STD_ID_HELP`.
- **IDs 1..9 reserved, tools start at 100.** An arbitrary
  convention that leaves room for M3+ additions to StdVocab
  (`--audit-id`, `--elevate-ttl`, `--pipe-schema` are candidates)
  without disturbing tool code that has already picked IDs.
- **`--color` is FKIND_ENUM; `--no-cap` is FKIND_STR.** libpdx-argv
  does not validate the color value against `{auto, always,
  never}` — that's the consumer's job. Similarly `--no-cap` value
  is opaque; libpdx-elevate + libpdx-cap decide whether a given
  KIND-name string is legal.
- **No short-form aliases in StdVocab::register_all.** The three
  common candidates (`-h`, `-v`, `-V`) all collide with per-tool
  vocabulary that predates the standard: cat's `-h` for
  human-readable, grep's `-v` for invert-match, ls's `-V` (unused
  historically but at risk). By keeping the standard vocabulary
  long-form-only, tools opt in per-alias.
- **`register_all` is non-leaf; 1-push aligns stack.** The nine
  `FlagSpec::register` calls all take three register args
  (rdi/rsi/rdx). rbx is pushed only to satisfy `rsp%16 == 0` at
  every nested call site — its value is not used.

## paideia-as conformance

- Module `StdVocab` (PascalCase basename).
- No `test`, no `cmp` in the module (only mov/lea/call/ret).
- Byte-length of each `STD_NAME_*` matches `strlen + 1` (verified
  by hand: `"help\0"` = 5, `"version\0"` = 8, etc.).
- `register_all` prologue: `push rbx` (rsp%16: 8→0). Epilogue:
  `pop rbx; ret`. Aligned for the nine nested calls.

## What did not land (queued for M3+)

- Cross-tool checker that verifies every P0 tool has actually
  called `StdVocab::register_all()` — filed as `libpdx-argv.M4-001`
  test-matrix line.
- `.pdxdoc` back-end for the standard flags — M3-002.
- `--schema` printing the tool's declared output schemas —
  M3-003 (StdVocab only registers the FLAG; the actual schema
  emission is Parser's M3 work).
