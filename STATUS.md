# libpdx-argv — status

**Wave:** R49 shared library
**Current milestone:** M1 (design + skeleton) — in progress

## Milestone rollup

| ID              | Title                                                        | State  |
|-----------------|--------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + ParsedArgs struct + long-flag grammar             | LANDED |
| M1-002 (#2)     | short-flag grammar one-per-hyphen (clustered → reject)       | open   |

See `design/tooling/r49-r50-plan.md` §5.12 in paideia-os for the full
milestone breakdown (M1–M5) and cross-repo dependencies.

## Local layout

- `design/architecture.md` — internal spec (record shape, state machine,
  paideia-as conformance).
- `src/parsed_args.pdx` — `ParsedArgs` module (error codes + slot storage).
- `src/parser.pdx` — `Parser` module (`parse_argv` entry point).
- `caps.decl` — libpdx-argv requires no caps of its own.
- `tests/` — empty until `libpdx-argv.M4-001` lands the parse-correctness matrix.
- `.plans/` — per-milestone implementation notes.
