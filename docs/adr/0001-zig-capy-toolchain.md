# ADR 0001: Zig and Capy UI Toolchain

- **Status:** Open — Zig candidate available; Capy pair not proven
- **Date:** 2026-10-11
- **Scope:** Zig compiler and required Capy UI toolkit compatibility

## Context

The project requires Zig for the engine and Capy UI for the desktop interface. `PROJECT.md` and `Agent.md` record an upstream review dated 2026-10-11: Capy names Zig 0.14.1, describes itself as pre-production, lists macOS backends as planned, and does not certify Windows ARM64. The same review noted Zig 0.17.0 as a newer release; newer does not imply Capy compatibility.

Zig 0.17.0 is now installed in the development environment. Its default global cache was inaccessible under the workspace policy, but `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` allows local builds without writing outside the repository. No Capy checkout or network access is available, and its documented target is Zig 0.14.1. Therefore Zig 0.17.0 is an evaluation compiler for independent core work, not an approved project-wide or Capy-compatible pin. Pinning the pair based only on an upstream version statement would not satisfy the compatibility gate.

## Decision

Defer the project-wide toolchain pin. Use installed Zig 0.17.0 only to evaluate Capy-independent core modules. Separately begin the Capy spike against Zig 0.14.1, the candidate stated by the dated project source review, then select an exact Capy commit and compiler only after a reproducible build and GUI compatibility spike. Do not represent the core evaluation compiler as Capy-compatible or replace Capy with another GUI framework.

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
