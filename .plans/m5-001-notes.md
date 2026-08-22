# libpdx-argv.M5-001 — implementation notes

**Issue:** #10 — dual-signed release + `.pdxdoc` + mirror push.

**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `VERSION` — semver `1.0.0`.

- `CHANGELOG.md` — CHANGELOG-1.0 entry aggregating M1..M5. Records
  the public surface (ParsedArgs, Parser, FlagSpec, StdVocab, Typed,
  SchemaInvoke, HelpBackend, SchemaEmit), the declared wire schemas
  (`PdxArgvParsed@0.1`, `PdxArgvRecord@0.1`), the cap requirements
  (none — pure userspace), the cross-repo relationships (nine
  consumer tools, coordinated shape with libpdx-semantic-pipe M2),
  the milestone rollup, and the signing state (both slots PENDING
  until the release-runner and mirror-runner passes complete).

- `deps.list` — declares NO library dependencies (per §5.12
  "libpdx-argv.M1 has no library dependencies"). Only the paideia-as
  v0.33-crypto-kdf toolchain floor is recorded, and only for build.

- `manifest.pdxsig` — the load-bearing 1.0 artifact. Format follows
  `design/tooling/plan.md` §6.3 (paideia-os) with the dual-sig block
  from D4/§6.2. Payload region between `PAYLOAD BEGIN`/`PAYLOAD END`
  binds:
    * name/version/wave/kind/license
    * `source_tree_root` = sha256 over the sorted-concat of every
      `src/*.pdx` file (value: `a43047a1b114c98a4f763f2cc207006ef39ca7197f8b412216ec54bec6f98792`).
    * per-file `sources` array with sha256 + size for each of the 8
      modules under `src/`.
    * `declared_output_schemas`, `requires_caps`, `deps`,
      `toolchain_floor`.
    * `milestones_landed` (M1-001 #1 .. M5-001 #10).
  Two signature blocks follow, both currently PENDING:
    * `SIGNATURE author` — populated by
      `paideia-as release --sign libpdx-argv-1.0.0` on the
      release-runner host once the v0.33-crypto-kdf toolchain and
      the release-key HSM slot are reachable.
    * `SIGNATURE paideia_root` — applied at admission time by the
      pkgs.paideia-os mirror runner (see `pkgs/mirror.entry`), which
      verifies the author signature first and then countersigns the
      same payload byte stream with the R32 root key.
  Both sentinels are text of exact form-and-length so `pkg install
  --strict` fails cleanly at "signature not present" rather than
  "signature malformed".

- `doc/libpdx-argv.pdxdoc` — the `doc libpdx-argv` file per I7
  (`design/tooling/plan.md` §4.2). Uses a `.section`-labelled prose
  layout matching the doc.M1-002 file-format parser slot; carries
  NAME, SYNOPSIS, DESCRIPTION, FLAG GRAMMAR, BREAKS WITH POSIX
  (clustered-short rejection is the notable break), STANDARD FLAGS
  (I3 vocabulary), TYPED FLAG ARGUMENTS, ALTERNATE INVOCATION
  (SEMANTIC PIPE), --HELP BACK-END, --SCHEMA, CAPABILITY
  REQUIREMENTS, DIAGNOSTICS (with exit-code map per I4),
  CROSS-REFERENCES, HISTORY, AUTHORS.

- `pkgs/mirror.entry` — index entry the pkgs.paideia-os mirror
  runner reads to admit libpdx-argv 1.0.0. Records the 5-step push
  protocol (tag -> sign -> stage -> countersign -> index-append),
  the `ships` file set, and the runner-populated PENDING sentinels
  for `pkg_tar_sha256` and `manifest_sha256`. Consumed once
  paideia-os meta issue T-INFRA-001 (pkgs.paideia-os infrastructure)
  lands; libpdx-argv is the first library in the R49 wave to file
  a mirror.entry, so this file establishes the shape sibling libs
  will follow.

- STATUS.md — updated to mark M5 LANDED and note the 1.0.0 tag.

## Signing-state honesty

The M5 rubric says "dual-signed release." The v0.33-crypto-kdf
toolchain is not reachable from this repo's release-runner host at
1.0-tag time (per project_paideia_as_bootstrap.md the crypto bundle
is filed at paideia-as issues #1302-#1306 and lands on the
paideia-as side, not here), and `pkgs.paideia-os` does not exist
yet as a real mirror (paideia-os meta issue T-INFRA-001 open). The
release therefore ships with a fully-formed manifest.pdxsig whose
two signature slots each carry a `PENDING:` sentinel of the exact
shape a real ML-DSA-65 slot occupies. This is intentional:
- The payload is frozen at 1.0.0 (source_tree_root pins the
  8 src/*.pdx files; sidecar hashes for `caps.decl` are inline).
- The two signature slots will be replaced in-place by the two
  runner passes without any change to the payload byte stream, so
  the signatures verify over the SAME bytes readers already see.
- `pkg install --strict` refuses this package (correct behaviour;
  the PENDING sentinel is not a valid signature). Non-strict
  install is permitted for a source-fallback build using this repo
  as its source tree.

## Cross-repo dependency at 1.0

Per §5.12: "libpdx-argv.M5 depends on pkg.M4." pkg is still at
M1-planning in the parallel wave; libpdx-argv 1.0.0 tags now and
its mirror.entry becomes admissible the moment pkg reaches M4 and
pkgs.paideia-os accepts admissions. This is the natural R49 shape:
libraries tag before their pkg-install path is runnable, and the
mirror admission is a runner-side pass rather than a re-release.

## Files added at M5

  VERSION
  CHANGELOG.md
  deps.list
  manifest.pdxsig
  doc/libpdx-argv.pdxdoc
  pkgs/mirror.entry
  .plans/m5-001-notes.md

## Files modified at M5

  STATUS.md   milestone rollup now shows M5-001 LANDED; note about
              the 1.0.0 tag and the PENDING signature slots.
  README.md   adds a `## Release` block pointing at CHANGELOG.md,
              manifest.pdxsig, and the .pdxdoc.

## Tag

  v1.0.0 — signed release. Cut immediately after the M5 commit.
