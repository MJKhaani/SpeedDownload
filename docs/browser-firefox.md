# Firefox client handoff (macOS preview)

The extension communicates only with the desktop client through its bundled
native messaging host. The host has no engine IPC code, never starts the engine,
and never creates jobs. The client owns engine connection, probing, and queueing.

- A single context-menu or intercepted download opens **Add Download**.
- A selected page area sends its unique links in one request (up to 100). The
  client opens **Add Multiple Downloads** with checkboxes, filtering, All/None,
  destination, and queue priority. Only confirmed links are queued.
- Magnets and `.torrent` downloads open **Add Torrent** for verified metadata,
  file selection, and tracker editing. Torrent detection includes URL suffix,
  browser filename, and `application/x-bittorrent` MIME type. Torrents selected
  from a multiple-link dialog receive their own torrent review before queueing.
- The toolbar and popup use icons generated from `Resources/logo.png`.

The popup offers **Grab new browser downloads automatically**, off by default.
When enabled, the extension pauses an eligible HTTP(S) download and hands it to
the client. The browser copy is canceled only after the client launch succeeds;
a failed handoff resumes it. Canceling the app's review dialog queues nothing.
Private browsing and downloads started by other extensions are skipped. Browser
cookies, authentication headers, and passwords are not forwarded.

The native host accepts only the configured Firefox extension ID or pinned
Chrome origin. It validates messages of at most 256 KiB, individual URLs of at
most 8 KiB, and batches of at most 100 URLs/128 KiB. It writes the bounded request
atomically to the user's private `Library/Application Support/Speed Download/BrowserInbox`
with 0600 file permissions in a 0700 directory, then opens the exact containing
app bundle using a `speeddownload://browser?request=<UUID>` token. The client
accepts only that known inbox location, validates and consumes the request, and
deduplicates retry tokens. Arbitrary filesystem paths and engine RPC methods
cannot be supplied by the browser. The acknowledgement means handed to the
client for review, not queued. A native-message transport failure retries once
with the same token.

The popup's status check reports whether the bundled client is available; it
does not connect to the engine. Selection uses the temporary `activeTab` grant
from the context-menu click and reads anchors intersecting the selected range
in the clicked frame.

Build the macOS app, then register the host for the current user:

```sh
bash macos/SpeedDownload/package-app.sh
bash extensions/firefox/install-macos.sh "dist/Speed Download.app"
```

For local development, load `extensions/firefox/manifest.json` as a temporary
extension using Firefox's `about:debugging` page. Reload the extension after
source or icon updates. If the app moves, rerun the host installer with its new
path. The installer does not modify profiles or install the extension.

The handlers and native bridge have local regression checks; a live browser
extension installation and store signing remain unverified. The Chrome preview
shares the handlers; see [Chrome setup](browser-chrome.md). Safari integration
remains separate work.

API references: [native manifests](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests),
[native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging),
[downloads.onCreated](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads/onCreated),
[downloads controls](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/downloads),
and [activeTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/activeTab_permission).

On startup, the macOS client recovers up to 100 pending browser inbox requests
and opens their review dialogs. Recovery never adds jobs without confirmation.
Duplicate delivery tokens are ignored before reading the consumed request file.

## Reference pages and expired links

Version 0.3.0 includes `reference_url` in handoffs when available: the page URL
for context-menu links and selections, or a bounded mapping from the download's
request to its originating tab (falling back to the browser download's `referrer`).
If the browser supplies no referrer, the app's Add dialog lets you enter a
reference page. The engine saves it with the job; the extension does not connect
to the engine. Reload the extension and install the updated native host together.

For an inactive HTTP(S) job, choose **Refresh Download Link…** to reopen its
reference page. Waiting jobs are paused first so they cannot start during refresh. Click the site's download button and hand off the fresh link
(using interception or Download with Speed Download). A handoff from the same
reference page opens **Replace Download Link** for the original job. Confirmation
is labeled **Replace Link & Restart** and removes the old partial data. Canceling
leaves the original job untouched. Sites requiring login or interaction remain
in the browser; automatic page scraping and cross-URL partial reuse are not
implemented. A pending refresh is held only while the client is running.

Automatic reference capture uses `tabs`, `webRequest`, and HTTP(S) host permissions.
Observation is nonblocking and does not request headers or bodies. It is enabled
only while automatic grabbing is enabled, ignores private tabs, and keeps at most
256 associations in memory; only entries under ten minutes old are used. The
browser may request permission approval when updating the extension. See the
[Chrome request API](https://developer.chrome.com/docs/extensions/reference/api/webRequest)
and [Firefox request API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/onBeforeRequest)
for the originating request and tab fields used by this bridge.
