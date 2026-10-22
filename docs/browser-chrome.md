# Chrome download handoff (macOS preview)

The Chrome extension supports the same client-only context-menu link handoff,
selected-area multiple-link review, and opt-in automatic download handoff as the
[Firefox extension](browser-firefox.md). Automatic handoff is off by default. Torrent filenames, MIME types, and magnet links open the macOS torrent review dialog for file selection and tracker editing before queueing.
It does not forward cookies or authentication headers from Chrome.

Build the app and the unpacked extension, then register the native host for
the current user:

```sh
bash macos/SpeedDownload/package-app.sh
bash extensions/chrome/build.sh
bash extensions/chrome/install-macos.sh "dist/Speed Download.app"
```

Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**,
and select `dist/SpeedDownload-Chrome-extension`. The extension's public key
pins local ID `fcjiipabggcamlocakedfideaamdgknn`; the native host allows only
that origin. The private key used to derive this local ID is not distributed.
Store-distributed builds will need their store ID in the native host manifest.
If the app moves, rerun `install-macos.sh` with its new path.

Chrome's [native messaging documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
specifies the per-user macOS host location and `allowed_origins` format.
The toolbar, popup, and manifest icons use the app logo. Reload the unpacked extension after updates. The extension has not been verified in a live Chrome session.
