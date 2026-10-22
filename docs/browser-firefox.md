# Firefox download handoff (macOS preview)

The Firefox extension adds **Download with Speed Download** to a link's context
menu. Selecting part of a page exposes **Download links in selection with Speed
Download**. That action reads links intersecting the selected range in the
clicked frame, removes duplicates, and sends at most 100 links. HTTP, HTTPS,
and v1 magnet links are supported. Each link and a fresh idempotency key go to
a bundled native host. The host accepts only the extension ID declared in
`extensions/firefox/manifest.json`, validates a 16 KiB maximum native message,
rejects credentials and fragments in URLs, reads the engine's saved default
download folder, and calls only `settings.get` and `jobs.add` through the
existing per-user IPC. The engine persists the job before the host acknowledges
it. If the native-message connection breaks, the extension retries once with
the same idempotency key so an acknowledged or uncertain submission cannot
create a duplicate job. Explicit engine rejections are reported without a
retry. No cookies, authorization headers, page text, or arbitrary IPC methods are
passed from Firefox.

The popup offers **Grab new Firefox downloads automatically**, off by default.
When enabled, the extension pauses an eligible public HTTP(S) download, sends
it to the engine, then cancels the Firefox copy only after the engine accepts
it. A rejected handoff resumes the Firefox download. Private browsing and
downloads started by another extension are skipped. Browser cookies and custom
request headers are not forwarded, so downloads requiring them may fail in the
engine. Firefox's [`downloads.onCreated`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/onCreated)
and [`downloads` controls](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads)
provide the event and pause/resume/cancel operations. The selection action
uses the [`activeTab` grant](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/activeTab_permission)
from the context menu click and injects a one-time script into that frame.

The toolbar popup checks whether the native host can reach the engine. This
read-only check does not start the engine or create a job. A link or browser
download handoff starts the bundled engine if needed.

Build the macOS bundle, place it at its intended final path, then register the
host for the current user:

```sh
bash macos/SpeedDownload/package-app.sh
bash extensions/firefox/install-macos.sh "dist/Speed Download.app"
```

Set the default download folder in Speed Download Settings → Downloads. The
native host connects to a running engine or starts the engine bundled in the
same app when it is closed, then waits briefly for its per-user IPC endpoint.
The engine starts in its own process group so it can outlive Firefox's
one-message native host. The GUI does not need to be open. For local development, load
`extensions/firefox/manifest.json` as a temporary extension through Firefox's
`about:debugging` page. Clicking its toolbar button shows connection status;
the extension shows the accepted count on its toolbar badge, or **!** if a
handoff fails. Browser installation,
extension signing, upgrade, and live-browser verification have not been done.
If the app is moved, rerun `install-macos.sh` with its new path. The installer
writes only the per-user Firefox native-host manifest; it does not modify the
browser profile or install the extension.

The native-messaging manifest location and `allowed_extensions` contract come
from [Mozilla's native manifests documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests).
Firefox's [native messaging documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
defines the framed stdin/stdout exchange. Authenticated downloads, Chrome-family
hosts, and Safari integration remain separate work.
