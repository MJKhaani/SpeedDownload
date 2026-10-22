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

async function handoff(raw, idempotencyKey = crypto.randomUUID()) {
  const url = supportedURL(raw);
  if (!url) throw new Error("Only public HTTP, HTTPS, and magnet links are supported");
  const request = { version: 1, action: "add", url, idempotency_key: idempotencyKey };
  let result;
  try {
    result = await browser.runtime.sendNativeMessage(HOST, request);
  } catch (firstError) {
    // The first host may have committed before its reply was lost.
    try { result = await browser.runtime.sendNativeMessage(HOST, request); }
    catch { throw firstError; }
  }
  if (!result || result.version !== 1 || result.ok !== true) {
    throw new Error(result?.error_message || "Speed Download rejected the link");
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

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === LINK_MENU) {
      await handoff(info.linkUrl);
      await showResult(1, 0, "Added one link to Speed Download.");
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
    let successes = 0;
    let failures = 0;
    for (const link of links.slice(0, MAX_SELECTION_LINKS)) {
      try { await handoff(link); successes += 1; }
      catch (error) { failures += 1; console.error("Speed Download link handoff failed:", error); }
    }
    await showResult(successes, failures,
      `Selected links: ${successes} added${failures ? `, ${failures} failed` : ""}.`);
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
    // Keep Firefox's original transfer available until the engine commits the job.
    await browser.downloads.pause(item.id);
  } catch { return; }
  let handedOff = false;
  try {
    await handoff(item.url);
    handedOff = true;
    await browser.downloads.cancel(item.id);
    await showResult(1, 0, "Browser download moved to Speed Download.");
  } catch (error) {
    console.error("Speed Download automatic handoff failed:", error);
    if (!handedOff) {
      try { await browser.downloads.resume(item.id); } catch { /* The browser may have removed it. */ }
      await showResult(0, 1, "Could not hand off the download; the browser kept it.");
    } else {
      await showResult(1, 1, "Queued in Speed Download, but the browser copy could not be canceled.");
    }
  }
});
