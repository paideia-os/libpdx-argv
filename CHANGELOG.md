# libpdx-argv — CHANGELOG

All notable changes to `libpdx-argv` are recorded here. The format is
loosely modelled on Keep-a-Changelog, adapted to the PaideiaOS milestone
rubric in `design/tooling/r49-r50-plan.md` §5.

## 1.0.0 — 2026-08-22

First signed release. Closes the R49 shared-library slot for CLI
argument parsing. All five milestones M1–M5 have landed and every
milestone issue (#1–#10 in `paideia-os/libpdx-argv`) is closed.

### Public surface

- `ParsedArgs` — the in-memory record every consumer reads after
  `parse_argv` returns (long-flag, short-flag, positional, typed
  slots; error-code constants for tool-side diagnostics).
- `Parser::parse_argv(argv_ptr, argc) -> u64` — the primary
  argv-input entry point (M1, M2).
- `FlagSpec::register(name_ptr, kind, id)` /
  `FlagSpec::reset()` — declarative flag registration (M2-001).
- `StdVocab::register_all()` — the I3 9-flag standard vocabulary
  (`--help`, `--version`, `--dry-run`, `--json`, `--schema`,
  `--verbose`, `--quiet`, `--color=`, `--no-cap:`; M2-002).
- `Typed::parse_int_u64` / `Typed::parse_size` /
  `Typed::parse_timespan` — typed-flag argument decoders (M2-001).
- `SchemaInvoke::parse_from_schema_record(rec_ptr, rec_len) -> u64`
  — alternate invocation via a `PdxArgvRecord@0.1`
  semantic-pipe wire form; converges on the same `ParsedArgs`
  (M3-001).
- `HelpBackend::fill_doc_argv(argv_slots, tool_name_ptr)` —
  `--help` back-end that synthesises argv for `doc <tool>`
  (M3-002).
- `SchemaEmit::register(schema_name_ptr)` /
  `SchemaEmit::get_count` / `SchemaEmit::get_name` —
  `--schema` declared-output-schema registry (M3-003).

### Wire schemas declared

- `PdxArgvParsed@0.1` — emitted when consumer opts into
  `--pdx-schema` (structured mirror of `ParsedArgs`; used by
  downstream tools that want to introspect a peer tool's parsed
  invocation without re-running the parser).
  **Correction (2026-08-25, `libpdx-argv.ENH-003`):** this schema was
  never implemented — `--pdx-schema` only ever set the `emit_schema`
  bit; no function in this repo has ever serialized `ParsedArgs` into
  this shape. Withdrawn from `caps.decl`/`pkgs/mirror.entry` rather
  than built, since no consumer depended on it. Left in place here
  rather than edited, per this repo's policy of not rewriting a
  signed release's history silently.
- `PdxArgvRecord@0.1` — the alternate-invocation wire form
  consumed by `SchemaInvoke::parse_from_schema_record`
  (schema-driven arg binding when libpdx-argv is called through
  a semantic pipe rather than through argv). **Note (ENH-003):** this
  is this library's *input* schema (`SchemaInvoke` decodes it; nothing
  here encodes it) — `declares_output_schemas:` was the wrong
  direction for it from the start; see `caps.decl`'s
  `consumes_input_schemas:` for the corrected framing.

Both schemas live in the same fingerprint namespace and bind to
`libpdx-semantic-pipe` M2 envelope framing (schema-registry-aware
binding, `libpdx-semantic-pipe.M3-001`).

### Capabilities requested

None. libpdx-argv is a pure userspace library; it makes no
syscalls of its own (see `caps.decl` in this repo). Consumers
declare their own caps.

### Cross-repo relationships (at 1.0)

- Consumers (direct): `pkg`, `shell`, `doc`, `ls`, `cat`, `cp`,
  `mv`, `rm`, `mkdir` (all nine R49+R50 P0 tools).
  **Correction (2026-08-25, `libpdx-argv.ENH-011`):** this overclaimed.
  A source-grep audit found only 6 of these 9 (`pkg`, `ls`, `cp`,
  `mkdir`, `mv`, `rm`) actually call into this library; `cat`, `doc`
  and `shell` do not, each for the reason recorded in README.md
  §Callers. Left in place rather than edited, per this repo's policy
  of not rewriting a signed release's history silently.
- Coordinated wire schema (shape only, no link):
  `libpdx-semantic-pipe` at M2 envelope framing.
- Runtime target: `doc` at ≥ M2 (`HelpBackend::fill_doc_argv`
  synthesises argv for `doc <tool>`).

### Milestone rollup

| ID              | Title                                                                                   | Issue | Landed at |
|-----------------|-----------------------------------------------------------------------------------------|-------|-----------|
| M1-001          | scaffold + ParsedArgs struct + long-flag grammar (`--foo bar` / `--foo=bar`)            | #1    | 2026-08-21 |
| M1-002          | short-flag grammar one-per-hyphen (clustered → reject, per D3)                          | #2    | 2026-08-21 |
| M2-001          | typed flag arguments (`--older-than 7d`, `--size > 1MB`)                                | #3    | 2026-08-21 |
| M2-002          | 9-flag standard vocabulary from I3                                                      | #4    | 2026-08-21 |
| M2-003          | positional-argument list handling (`--` sentinel, `:` separator)                        | #5    | 2026-08-21 |
| M3-001          | alternate invocation: typed schema record → ParsedArgs                                  | #6    | 2026-08-21 |
| M3-002          | `--help` back-end integration with `doc <tool>`                                         | #7    | 2026-08-21 |
| M3-003          | `--schema` prints tool's declared output schemas                                        | #8    | 2026-08-21 |
| M4-001          | parse-correctness matrix + clustered-short rejection + typed diagnostics + `--help` RT  | #9    | 2026-08-22 |
| M5-001          | dual-signed release + `.pdxdoc` + mirror push                                            | #10   | 2026-08-22 |

### Signing state at 1.0

`manifest.pdxsig` in this release contains the payload
(`name=libpdx-argv`, `version=1.0.0`, `source_tree_sha256`, the
per-file `sources` array, the `declared_output_schemas` block,
and the `deps` block) plus two ML-DSA-65 signature slots:

- `author_pk = paideia-os-team` — signed with the R49 author key
  once the paideia-as v0.33-crypto-kdf toolchain and the
  `paideia-as release --sign` subcommand are reachable from the
  release-runner host. Until then the slot carries the string
  `PENDING:paideia-os-team-key@v0.33` and `pkg install --strict`
  will refuse the package (as designed — I5.a).
- `paideia_root_pk` — the R32-mint countersignature applied by
  `pkgs.paideia-os` at admission time. Until the pkgs.paideia-os
  mirror lands (paideia-os meta issue `T-INFRA-001`), the slot
  carries the string `PENDING:paideia_root_pk@R32-mint`.

Both slots are populated in the same release-runner pass that
first signs and then admits to the mirror; the on-disk shape
above is what gets replaced in place. Neither placeholder is a
valid ML-DSA-65 signature; both are text sentinels of the exact
length + form the pkg-install verifier looks for, so a `pkg
install` under `--strict` fails cleanly at "signature not
present" rather than at "signature malformed". See §11.2 of
`design/user/model.md` for the verify path.

### Notes

- No API breaks planned before 2.0. The `PdxArgvRecord@0.1`
  wire form is versioned; a `@0.2` may add fields (backward
  compatible per `libpdx-semantic-pipe.M3-002` version-tolerance
  rules).
- The M4 smoke driver is not shipped in the binary package;
  `tests/*.pdx` stay in-tree only.
