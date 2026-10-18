const HOST = "com.mjkhaani.speeddownload";
const MENU = "speed-download-link";

browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.create({
    id: MENU,
    title: "Download with Speed Download",
    contexts: ["link"],
  });
});

browser.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== MENU || typeof info.linkUrl !== "string") return;
  let result;
  try {
    const url = new URL(info.linkUrl);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) {
      throw new Error("Only public HTTP and HTTPS links are supported");
    }
    result = await browser.runtime.sendNativeMessage(HOST, {
      version: 1,
      action: "add",
      url: info.linkUrl,
      idempotency_key: crypto.randomUUID(),
    });
    if (!result || result.version !== 1 || result.ok !== true) {
      throw new Error(result?.error_message || "Speed Download rejected the link");
    }
    await browser.action.setBadgeBackgroundColor({ color: "#278746" });
    await browser.action.setBadgeText({ text: "OK" });
  } catch (error) {
    console.error("Speed Download handoff failed:", error.message);
    await browser.action.setBadgeBackgroundColor({ color: "#B52B2B" });
    await browser.action.setBadgeText({ text: "!" });
  }
});
