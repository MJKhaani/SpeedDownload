# ADR 0001: Zig and Capy UI Toolchain

- **Status:** Open — no compiler/dependency pin approved
- **Date:** 2026-10-11
- **Scope:** Zig compiler and required Capy UI toolkit compatibility

## Context

The project requires Zig for the engine and Capy UI for the desktop interface. `PROJECT.md` and `Agent.md` record an upstream review dated 2026-10-11: Capy names Zig 0.14.1, describes itself as pre-production, lists macOS backends as planned, and does not certify Windows ARM64. The same review noted Zig 0.17.0 as a newer release; newer does not imply Capy compatibility.

This environment has no installed Zig compiler, no Capy checkout, and no network access. There is no build manifest to test. Therefore no exact working Zig/Capy pair can be truthfully selected today. Pinning based only on an upstream version statement would not satisfy the compatibility gate.

## Decision

Defer the toolchain pin. Begin evaluation against Zig 0.14.1 as the candidate stated by the dated project source review, then select an exact Capy commit and compiler only after a reproducible build and GUI compatibility spike. Do not use an unverified newer Zig or replace Capy with another GUI framework.

Until evidence is recorded, the GUI and all platform targets remain unvalidated; macOS GUI remains blocked pending backend validation. Keep headless/core work independent of Capy.

## Required evidence to close this ADR

1. Record exact Zig version and archive/checksum, exact Capy commit, dependency/license notices, and reproducible build commands.
2. Build a minimal Capy window and exercise native events, text, lists, scrolling, progress visualization, keyboard access, theme, DPI, and packaging.
3. Run target-specific builds and native smoke tests from [`../support-matrix.md`](../support-matrix.md); do not infer runtime support from cross-compilation.
4. Document backend patches/adapters and upstream status. Reopen this ADR for compiler or Capy upgrades.

## Consequences

- Product UI implementation is gated until the required Capy APIs and target backends are proven.
- Portable engine and headless CLI work can proceed without Capy imports.
- No platform support claim is made by this decision.
