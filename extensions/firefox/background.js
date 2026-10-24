const HOST = "com.mjkhaani.speeddownload";
const LINK_MENU = "speed-download-link";
const SELECTION_MENU = "speed-download-selection";
const MAX_SELECTION_LINKS = 100;

browser.runtime.onInstalled.addListener(async () => {
  await browser.contextMenus.removeAll();
  browser.contextMenus.create({ id: LINK_MENU, title: "Download with Speed Download", contexts: ["link"] });
  browser.contextMenus.create({
    id: SELECTION_MENU,
    title: "Download links in selection with Speed Download",
    contexts: ["selection"],
  });
});

function supportedURL(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 8192) return null;
  try {
    const parsed = new URL(raw);
    if (parsed.protocol === "magnet:" && parsed.searchParams.has("xt")) return parsed.href;
    if (!["http:", "https:"].includes(parsed.protocol) || !parsed.host ||
        parsed.username || parsed.password || parsed.hash) return null;
    return parsed.href;
  } catch { return null; }
}

async function handoff(raw, idempotencyKey = crypto.randomUUID(), torrent = false, referenceURL = null) {
  const url = supportedURL(raw);
  if (!url) throw new Error("Only public HTTP, HTTPS, and magnet links are supported");
  const parsed = new URL(url);
  const isTorrent = torrent || parsed.protocol === "magnet:" || /\.torrent$/i.test(decodeURIComponent(parsed.pathname));
  const reference_url = pageReference(referenceURL);
  return sendToClient({ version: 1, action: isTorrent ? "torrent" : "add", url, idempotency_key: idempotencyKey,
    ...(reference_url ? { reference_url } : {}) });
}

function pageReference(raw) {
  if (typeof raw !== "string") return null;
  try {
    const page = new URL(raw);
    page.hash = "";
    return /^https?:$/.test(page.protocol) ? supportedURL(page.href) : null;
  } catch { return null; }
}

async function sendToClient(request) {
  let result;
  try {
    result = await browser.runtime.sendNativeMessage(HOST, request);
  } catch (firstError) {
    try { result = await browser.runtime.sendNativeMessage(HOST, request); }
    catch { throw firstError; }
  }
  if (!result || result.version !== 1 || result.ok !== true || result.dialog_opened !== true) {
    throw new Error(result?.error_message || "Could not open Speed Download");
  }
  return result;
}

async function showResult(successes, failures, message) {
  await browser.action.setBadgeBackgroundColor({ color: failures ? "#B52B2B" : "#278746" });
  await browser.action.setBadgeText({ text: failures ? "!" : String(successes) });
  await browser.storage.local.set({ lastResult: message });
}

function linksInSelection() {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return [];
  const ranges = Array.from({ length: selection.rangeCount }, (_, index) => selection.getRangeAt(index));
  const urls = new Set();
  for (const anchor of document.querySelectorAll("a[href]")) {
    if (urls.size >= 100) break;
    if (!ranges.some((range) => range.intersectsNode(anchor))) continue;
    const href = anchor.href;
    try {
      const url = new URL(href);
      if (((url.protocol === "http:" || url.protocol === "https:") &&
           url.host && !url.username && !url.password && !url.hash) ||
          (url.protocol === "magnet:" && url.searchParams.has("xt"))) {
        if (href.length <= 8192) urls.add(href);
      }
    } catch { /* Ignore malformed page links. */ }
  }
  return [...urls];
}

// Keep a bounded, short-lived association with the originating tab. HTTP
// referrer policy can otherwise reduce a full page address to just its origin.
let automaticReferenceCapture = false;
const requestPages = new Map();
const downloadPages = new Map();
const referenceCaptureReady = browser.storage.local.get("automaticGrab").then(({ automaticGrab = false }) => {
  automaticReferenceCapture = automaticGrab;
}).catch(() => {});
browser.storage.onChanged?.addListener((changes, area) => {
  if (area === "local" && changes.automaticGrab) {
    automaticReferenceCapture = changes.automaticGrab.newValue === true;
    if (!automaticReferenceCapture) { requestPages.clear(); downloadPages.clear(); }
  }
});

function rememberDownloadPage(url, entry) {
  const normalized = supportedURL(url);
  if (!normalized || !/^https?:/i.test(normalized)) return;
  downloadPages.delete(normalized);
  downloadPages.set(normalized, entry);
  while (downloadPages.size > 256) downloadPages.delete(downloadPages.keys().next().value);
}

if (browser.webRequest?.onBeforeRequest && browser.tabs) {
  browser.webRequest.onBeforeRequest.addListener((details) => {
    referenceCaptureReady.then(() => {
      if (!automaticReferenceCapture || details.incognito || details.tabId < 0) return;
      let entry = requestPages.get(details.requestId);
      if (!entry) {
        const originPage = pageReference(details.originUrl || details.documentUrl);
        const page = originPage ? Promise.resolve(originPage) : browser.tabs.get(details.tabId).then((tab) => {
          if (tab.incognito) return null;
          const candidate = pageReference(tab.url);
          if (!candidate || !details.initiator || details.initiator === "null") return null;
          try { return new URL(candidate).origin === new URL(details.initiator).origin ? candidate : null; }
          catch { return null; }
        }).catch(() => null);
        entry = { page, created: Date.now() };
        requestPages.set(details.requestId, entry);
        while (requestPages.size > 256) requestPages.delete(requestPages.keys().next().value);
      }
      rememberDownloadPage(details.url, entry);
    });
  }, { urls: ["http://*/*", "https://*/*"] });
  browser.webRequest.onBeforeRedirect.addListener((details) => {
    const entry = requestPages.get(details.requestId);
    if (entry) rememberDownloadPage(details.redirectUrl, entry);
  }, { urls: ["http://*/*", "https://*/*"] });
  for (const event of [browser.webRequest.onCompleted, browser.webRequest.onErrorOccurred]) {
    event.addListener((details) => { requestPages.delete(details.requestId); }, { urls: ["http://*/*", "https://*/*"] });
  }
}

async function downloadReference(item) {
  const entry = downloadPages.get(supportedURL(item.url)) || downloadPages.get(supportedURL(item.finalUrl));
  if (entry && Date.now() - entry.created < 10 * 60 * 1000) {
    const page = await entry.page;
    if (page) return page;
  }
  return pageReference(item.referrer);
}

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === LINK_MENU) {
      await handoff(info.linkUrl, crypto.randomUUID(), false, info.pageUrl || tab?.url);
      await showResult(1, 0, "Review this download in Speed Download.");
      return;
    }
    if (info.menuItemId !== SELECTION_MENU || !Number.isInteger(tab?.id)) return;
    const injected = await browser.scripting.executeScript({
      target: { tabId: tab.id, frameIds: [info.frameId ?? 0] },
      func: linksInSelection,
    });
    const links = injected[0]?.result || [];
    if (links.length === 0) {
      await showResult(0, 1, "No supported links were found in the selected area.");
      return;
    }
    if (links.length === 1) {
      await handoff(links[0], crypto.randomUUID(), false, info.pageUrl || tab?.url);
      await showResult(1, 0, "Review this download in Speed Download.");
    } else {
      const urls = links.slice(0, MAX_SELECTION_LINKS);
      if (urls.reduce((total, url) => total + new TextEncoder().encode(url).length, 0) > 128 * 1024) {
        throw new Error("This selection is too large. Select fewer links.");
      }
      const reference_url = pageReference(info.pageUrl || tab?.url);
      await sendToClient({ version: 1, action: "batch", urls, idempotency_key: crypto.randomUUID(),
        ...(reference_url ? { reference_url } : {}) });
      await showResult(urls.length, 0, `Review ${urls.length} links in Speed Download and choose which to download.`);
    }
  } catch (error) {
    console.error("Speed Download handoff failed:", error);
    await showResult(0, 1, error.message || "Could not send the selected links.");
  }
});

browser.downloads.onCreated.addListener(async (item) => {
  if (item.incognito || item.byExtensionId || item.state !== "in_progress" ||
      !supportedURL(item.url) || !/^https?:/i.test(item.url)) return;
  const { automaticGrab = false } = await browser.storage.local.get("automaticGrab");
  if (!automaticGrab) return;
  try {
    // Keep the original transfer available until the client accepts the handoff.
    await browser.downloads.pause(item.id);
  } catch { return; }
  let handedOff = false;
  try {
    const torrent = /\.torrent$/i.test(item.filename || "") ||
      (item.mime || "").toLowerCase().split(";", 1)[0] === "application/x-bittorrent";
    await handoff(item.finalUrl || item.url, crypto.randomUUID(), torrent, await downloadReference(item));
    handedOff = true;
    await browser.downloads.cancel(item.id);
    await showResult(1, 0, "Review this download in Speed Download.");
  } catch (error) {
    console.error("Speed Download automatic handoff failed:", error);
    if (!handedOff) {
      try { await browser.downloads.resume(item.id); } catch { /* The browser may have removed it. */ }
      await showResult(0, 1, "Could not hand off the download; the browser kept it.");
    } else {
      await showResult(1, 1, "Opened in Speed Download, but the browser copy could not be canceled.");
    }
  }
});
