# Firefox link handoff (macOS preview)

The Firefox extension adds **Download with Speed Download** to a link's context
menu. It sends only the clicked HTTP or HTTPS URL and a fresh idempotency key to
a bundled native host. The host accepts only the extension ID declared in
`extensions/firefox/manifest.json`, validates a 16 KiB maximum native message,
rejects credentials and fragments in URLs, reads the engine's saved default
download folder, and calls only `settings.get` and `jobs.add` through the
existing per-user IPC. The engine persists the job before the host acknowledges
it. No cookies, authorization headers, page text, or arbitrary IPC methods are
passed from Firefox.

Build the macOS bundle, place it at its intended final path, then register the
host for the current user:

```sh
bash macos/SpeedDownload/package-app.sh
bash extensions/firefox/install-macos.sh "dist/Speed Download.app"
```

Set the default download folder in Speed Download Settings → Downloads and
keep the GUI or engine running. For local development, load
`extensions/firefox/manifest.json` as a temporary extension through Firefox's
`about:debugging` page. The extension shows **OK** on its toolbar badge after
the engine accepts a link, or **!** if handoff fails. Browser installation,
extension signing, upgrade, and live-browser verification have not been done.
If the app is moved, rerun `install-macos.sh` with its new path. The installer
writes only the per-user Firefox native-host manifest; it does not modify the
browser profile or install the extension.

The native-messaging manifest location and `allowed_extensions` contract come
from [Mozilla's native manifests documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests).
Firefox's [native messaging documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
defines the framed stdin/stdout exchange. This preview is limited to explicit
link clicks; page interception, authenticated downloads, Chrome-family hosts,
and Safari integration remain separate work.
