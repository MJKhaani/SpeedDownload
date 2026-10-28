# License and Third-Party Notices

## Application license

The application source in this repository is offered under the MIT License; see [`../LICENSE`](../LICENSE). SPDX identifier: `MIT`.

## Third-party components

No third-party source dependencies or binaries are currently vendored. Native projects declare platform dependencies independently: Apple SDK/SwiftUI; .NET 10/WPF in the temporary Windows alpha, with WinUI 3/Windows App SDK required for the target Windows client; and GTK 4 plus JSON-GLib through system packages. Review each platform's redistribution and notice requirements before packaging. Review each future protocol, database, native binding, and packaging dependency for license compatibility and target support before adding it. Capy was removed from the project architecture; see [ADR 0001](adr/0001-native-guis-local-ipc.md).

This file is an initial inventory, not a complete dependency audit or legal opinion. Update it alongside dependency changes and include applicable notices and an SBOM with binary releases.
