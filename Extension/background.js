// Hands downloads over to Notch.
//
// When you click a download, the browser's copy is paused while Notch is asked to take it.
// Notch answers once the server has replied: if it accepted, the browser's copy is cancelled
// and removed from the list; otherwise (Notch not running, turned off, file type it doesn't
// take, error) the browser simply carries on. A download is never lost.

const PORT = 47821; // must match BrowserBridgeService.port
const BASE = `http://127.0.0.1:${PORT}`;
const TIMEOUT_MS = 20000; // Notch gives up after 10 s, so this is only a safety net
const api = globalThis.browser ?? globalThis.chrome;

async function isEnabled() {
  const { enabled = true } = await api.storage.local.get("enabled");
  return enabled;
}

async function updateBadge(reachable) {
  const enabled = await isEnabled();
  const text = !enabled ? "OFF" : reachable === false ? "!" : "";
  await api.action.setBadgeText({ text });
  await api.action.setBadgeBackgroundColor({ color: enabled ? "#d93025" : "#777777" });
  await api.action.setTitle({
    title: !enabled
      ? "Notch: off (click to take over downloads)"
      : reachable === false
        ? "Notch isn't reachable. Is it running, with browser downloads turned on in Settings?"
        : "Notch: taking over downloads (click to turn off)",
  });
}

async function request(path, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(BASE + path, {
      ...options,
      headers: { "Content-Type": "application/json", "X-Notch-Bridge": "1", ...(options.headers ?? {}) },
      signal: controller.signal,
    });
    return response.ok ? await response.json() : null;
  } finally {
    clearTimeout(timer);
  }
}

async function ping() {
  try {
    const answer = await request("/ping");
    await updateBadge(Boolean(answer?.ok && answer?.enabled));
  } catch {
    await updateBadge(false);
  }
}

async function cookieHeader(url) {
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

function baseName(path) {
  return (path ?? "").split(/[\\/]/).pop();
}

function canHandOver(item) {
  const url = item.finalUrl || item.url || "";
  if (!/^https?:\/\//i.test(url)) return false; // blob:, data:, file: can't be fetched again
  if (/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//i.test(url)) return false;
  if (item.incognito) return false; // keep private windows private
  if (item.byExtensionId) return false; // started by an extension, maybe on purpose
  return item.state === undefined || item.state === "in_progress";
}

api.downloads.onCreated.addListener(async (item) => {
  if (!canHandOver(item) || !(await isEnabled())) return;
  try {
    await api.downloads.pause(item.id);
  } catch {
    return; // already finished (tiny file) or can't be paused: leave it with the browser
  }

  const url = item.finalUrl || item.url;
  let accepted = false;
  try {
    const answer = await request("/download", {
      method: "POST",
      body: JSON.stringify({
        url,
        filename: baseName(item.filename) || null,
        referrer: item.referrer || null,
        mime: item.mime || null,
        totalBytes: item.totalBytes > 0 ? item.totalBytes : null,
        userAgent: navigator.userAgent,
        cookies: await cookieHeader(url),
      }),
    });
    accepted = answer?.accepted === true;
    await updateBadge(answer !== null);
  } catch {
    await updateBadge(false);
  }

  if (accepted) {
    try {
      await api.downloads.cancel(item.id);
      await api.downloads.erase({ id: item.id });
    } catch {
      // Already gone.
    }
  } else {
    try {
      await api.downloads.resume(item.id);
    } catch {
      // The user may have cancelled it meanwhile.
    }
  }
});

api.action.onClicked.addListener(async () => {
  await api.storage.local.set({ enabled: !(await isEnabled()) });
  await ping();
});

api.runtime.onStartup.addListener(ping);
api.runtime.onInstalled.addListener(ping);
