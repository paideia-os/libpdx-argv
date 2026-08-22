# libpdx-argv.M3-002 — implementation notes

**Issue:** #7 — `--help` back-end integration with `doc <tool>`.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/help_backend.pdx` — new `HelpBackend` module. Public surface:
  - `HelpBackend::DOC_TOOL_NAME : [u8; 4] = "doc\0"` — the
    canonical .rodata symbol every tool's synthesized `--help`
    argv[0] shares.
  - `HelpBackend::fill_doc_argv(out_argv_slot_ptr, tool_name_ptr)
    -> ()` — leaf helper that writes two qwords into a caller-owned
    `[u64; 2]` scratch: slot 0 = &DOC_TOOL_NAME, slot 1 = tool_name.
- `design/architecture.md` §10.2 — the "why an argv-fill primitive
  rather than a fn-pointer dispatcher" rationale (circular dep +
  bootstrap-scope static linking) and the consumer wiring pattern.
- `STATUS.md` — the M3 consumer wiring block includes the `--help`
  branch: on `find_flag_by_id(STD_ID_HELP)` match, call
  `fill_doc_argv` into a local `[u64; 2]`, then `doc_dispatch` with
  argv = &slot0 and argc = 2.

## Design decisions

- **Argv-fill primitive, not a fn-pointer dispatcher.** libpdx-argv
  cannot statically depend on `doc` — the reverse dep already holds
  (doc uses libpdx-argv). A fn-pointer table would work but adds
  per-invocation registration state and an indirect call. At
  bootstrap-scope every P0 tool is one statically-linked binary
  that knows at link time which `doc_dispatch` symbol to call, so
  handing back argv slots is the minimum viable integration.
- **Shared canonical `DOC_TOOL_NAME` symbol.** Every consumer's
  synthesized argv[0] points at the same .rodata address, so shell-
  side audit-record consumers can recognise the "doc" tool without
  normalising per-caller whitespace or case. Cost is 4 bytes.
- **Tool name is caller-supplied, not registered here.** Registering
  the tool name in a HelpBackend .bss slot would introduce state that
  needs a reset; passing it in each call keeps the helper leaf and
  reset-free.
- **Not `render_help(exit_code)` — the caller owns the exit path.**
  A `render_help` shape that internally invoked `doc_dispatch` would
  either need the fn-pointer registration or a hard link. The
  argv-fill shape lets the caller decide whether to in-process-call
  `doc_dispatch` (bootstrap R49/R50), fork/exec `doc` (R51+ once
  process spawn substrate lands), or hand the argv to a mediating
  child-supervisor (post-R60 GUI-shell scenarios). Same helper, three
  transports.

## paideia-as conformance

- Module `HelpBackend` (PascalCase basename).
- `fill_doc_argv` is a leaf; no push/pop parity to preserve.
- No `test` mnemonic; no `cmp` in the module (a pure two-store fn).
- `r11` used only for `lea r11, [rip + DOC_TOOL_NAME]` (address
  load); never live across a call.
- Two qword stores at [rdi+0] and [rdi+8] use imm8 displacements,
  well within the paideia-as encoder envelope.

## Cross-module linkage

None. HelpBackend has no dependencies on `Parser`, `ParsedArgs`,
`FlagSpec`, or any other libpdx-argv module. The consumer calls
`ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)` to detect the
flag; that's a `ParsedArgs`+`StdVocab` couplement the consumer already
holds from M2.

## What did not land (queued for M4+)

- Consumer-side smoke test for the round-trip (`--help` seen →
  `fill_doc_argv` → `doc_dispatch` renders the tool's .pdxdoc) —
  `libpdx-argv.M4-001` test-matrix line "--help render round-trip
  via doc".
- Fork/exec-based `doc` invocation for the post-R51 substrate — the
  argv-fill shape already accommodates it; wiring lands as part of
  the process-spawn milestone.
- `doc --plain` back-channel (rendering without paging) — the M3
  integration always uses `doc_dispatch` with the default paging
  behaviour; consumers wanting `--plain` synthesize a 3-slot argv
  themselves.
