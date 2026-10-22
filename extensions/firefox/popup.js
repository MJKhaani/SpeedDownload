const HOST = "com.mjkhaani.speeddownload";
const status = document.getElementById("status");
const refresh = document.getElementById("refresh");
const automatic = document.getElementById("automatic");
const lastResult = document.getElementById("last-result");

browser.storage.local.get(["automaticGrab", "lastResult"]).then((saved) => {
  automatic.checked = saved.automaticGrab === true;
  lastResult.textContent = saved.lastResult || "";
});
automatic.addEventListener("change", async () => {
  await browser.storage.local.set({ automaticGrab: automatic.checked });
});

async function updateStatus() {
  refresh.disabled = true;
  status.textContent = "Checking connection…";
  try {
    const result = await browser.runtime.sendNativeMessage(HOST, {
      version: 1,
      action: "status",
    });
    if (!result || result.version !== 1 || result.ok !== true ||
        typeof result.engine_running !== "boolean") {
      status.textContent = "The app could not be reached";
    } else {
      status.textContent = result.engine_running
        ? "App installed · Engine running"
        : "App installed · Engine stopped";
    }
  } catch {
    status.textContent = "App connection unavailable";
  } finally {
    refresh.disabled = false;
  }
}

refresh.addEventListener("click", updateStatus);
updateStatus();
