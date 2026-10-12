# ADR 0001: Zig and Capy UI Toolchain

- **Status:** Open — Zig candidate available; Capy pair not proven
- **Date:** 2026-10-11
- **Scope:** Zig compiler and required Capy UI toolkit compatibility

## Context

The project requires Zig for the engine and Capy UI for the desktop interface. A fresh review of the [Capy upstream README](https://github.com/capy-ui/capy#readme) on 2026-10-12 still finds that Capy targets Zig 0.14.1 and says it is not ready for production. It lists macOS M1 and x86_64 as planned, does not list Windows ARM64, and its component table marks menus unavailable on all listed platforms and scrolling unavailable on macOS. Those gaps block the specified production UI, which needs menus and a scrolling download list. The same review notes Zig 0.17.0 as a newer release; newer does not imply Capy compatibility.

Zig 0.17.0 is installed in the development environment and builds the independent core. A local Capy master checkout (commit `fd77077e296a969ae258c595e75a0723183b3138`) was attempted with Zig 0.17.0; compilation fails because Capy's source still uses the removed `usingnamespace` declaration. Capy 0.4.1 was also attempted with Zig 0.14.1, its declared minimum, on macOS. Compilation reached the macOS backend but failed because the `objc` module was unavailable. Its dependency package could not be resolved from GitHub in this environment. A temporary attempt to repair the extracted dependency metadata was not a reproducible upstream build and is not adopted. The GUI source is therefore only a layout prototype, not a build target.

## Decision

Defer the project-wide toolchain pin. Use installed Zig 0.17.0 only to evaluate Capy-independent core modules. Separately begin the Capy spike against Zig 0.14.1, the candidate stated by the dated project source review, then select an exact Capy commit and compiler only after a reproducible build and GUI compatibility spike. Do not represent the core evaluation compiler as Capy-compatible or replace Capy with another GUI framework.

Until evidence is recorded, the GUI and all platform targets remain unvalidated; the GUI is blocked by toolchain incompatibility, the unresolved macOS dependency, and missing required toolkit components. Keep headless/core work independent of Capy.

## Required evidence to close this ADR

1. Record exact Zig version and archive/checksum, exact Capy commit, dependency/license notices, and reproducible build commands.
2. Build a minimal Capy window and exercise native events, text, lists, scrolling, progress visualization, keyboard access, theme, DPI, and packaging.
3. Run target-specific builds and native smoke tests from [`../support-matrix.md`](../support-matrix.md); do not infer runtime support from cross-compilation.
4. Document backend patches/adapters and upstream status. Reopen this ADR for compiler or Capy upgrades.

## Consequences

- Product UI implementation is gated until the required Capy APIs and target backends are proven.
- Portable engine and headless CLI work can proceed without Capy imports.
- No platform support claim is made by this decision.
