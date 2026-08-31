// Audify Tab Volume — service worker.
//
// Bridges the browser to the Audify app over a loopback WebSocket. The app owns the UI and the
// persisted levels; this side owns tab enumeration and actually applying gain.
//
// A note on lifetime: an MV3 service worker is evicted aggressively, but an open WebSocket counts
// as activity, and the alarm below revives the worker if it is ever torn down while the app is
// still running.

const DEFAULT_PORT = 17843;
const PROTOCOL_VERSION = 1;
const RECONNECT_BASE_MS = 1000;
const RECONNECT_MAX_MS = 30000;
const TAB_REPORT_DEBOUNCE_MS = 150;
const KEEPALIVE_ALARM = 'audify-keepalive';

/** @type {WebSocket | null} */
let socket = null;
let reconnectAttempts = 0;
let reconnectTimer = null;
let reportTimer = null;
let paired = false;

/** Intended gain per tab id, mirrored from the app. */
const tabGains = new Map();
/** Intended mute state per tab id. */
const tabMutes = new Map();

// MARK: - Settings

async function readSettings() {
  const stored = await chrome.storage.local.get(['token', 'port', 'enabled']);
  return {
    token: (stored.token || '').trim().toUpperCase(),
    port: Number(stored.port) || DEFAULT_PORT,
    enabled: stored.enabled !== false,
  };
}

// MARK: - Connection

async function connect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = null;

  const { token, port, enabled } = await readSettings();
  if (!enabled) {
    setBadge('off', '#8e8e93');
    return;
  }
  if (!token) {
    // Nothing to try until the user pastes the pairing code from the app.
    setBadge('!', '#ff9500');
    return;
  }
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return;
  }

  try {
    socket = new WebSocket(`ws://127.0.0.1:${port}`);
  } catch (error) {
    scheduleReconnect();
    return;
  }

  socket.addEventListener('open', () => {
    reconnectAttempts = 0;
    send({
      type: 'hello',
      token,
      browser: detectBrowserName(),
      version: PROTOCOL_VERSION,
    });
  });

  socket.addEventListener('message', (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (error) {
      return;
    }
    handleMessage(message);
  });

  socket.addEventListener('close', () => {
    paired = false;
    socket = null;
    setBadge('', '#8e8e93');
    scheduleReconnect();
  });

  socket.addEventListener('error', () => {
    // 'close' always follows, so reconnection is handled there.
  });
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.min(RECONNECT_BASE_MS * 2 ** reconnectAttempts, RECONNECT_MAX_MS);
  reconnectAttempts += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function send(message) {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(message));
  }
}

function handleMessage(message) {
  switch (message.type) {
    case 'welcome':
      paired = true;
      setBadge('', '#34c759');
      reportTabs();
      break;

    case 'rejected':
      paired = false;
      setBadge('!', '#ff3b30');
      chrome.storage.local.set({ lastError: message.reason || 'Rejected by Audify' });
      if (socket) socket.close();
      break;

    case 'requestTabs':
      reportTabs();
      break;

    case 'setVolume':
      applyVolume(message.tabId, Number(message.volume));
      break;

    case 'setMuted':
      applyMute(message.tabId, Boolean(message.muted));
      break;

    case 'siteDefaults':
      // Levels are pushed per tab, so nothing to do here beyond keeping the app's shape.
      break;

    default:
      break;
  }
}

function detectBrowserName() {
  const brands = navigator.userAgentData?.brands || [];
  const ignored = /not.a.brand|chromium/i;
  const named = brands.map((entry) => entry.brand).find((brand) => !ignored.test(brand));
  return named || 'Chromium';
}

function setBadge(text, color) {
  chrome.action.setBadgeText({ text });
  if (color) chrome.action.setBadgeBackgroundColor({ color });
}

// MARK: - Applying levels

async function applyVolume(tabId, volume) {
  if (!Number.isFinite(tabId) || !Number.isFinite(volume)) return;
  const clamped = Math.max(0, Math.min(volume, 5));
  tabGains.set(tabId, clamped);

  try {
    // Sent to every frame, so audio inside iframes is covered too.
    await chrome.tabs.sendMessage(tabId, { type: 'audify:setGain', gain: clamped });
  } catch (error) {
    // No content script in this tab (a chrome:// page, the store, a PDF viewer). Mute still works.
  }
  scheduleTabReport();
}

async function applyMute(tabId, muted) {
  if (!Number.isFinite(tabId)) return;
  tabMutes.set(tabId, muted);
  try {
    // Native tab muting: instant, reliable, and works even where scripts cannot run.
    await chrome.tabs.update(tabId, { muted });
  } catch (error) {
    tabMutes.delete(tabId);
  }
  scheduleTabReport();
}

/// Re-applies the intended gain after a navigation replaces the document.
async function reapply(tabId) {
  const gain = tabGains.get(tabId);
  if (gain === undefined || gain === 1) return;
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'audify:setGain', gain });
  } catch (error) {
    // Frame not ready yet; the content script asks for its gain on load as a backstop.
  }
}

// MARK: - Reporting

function scheduleTabReport() {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(reportTabs, TAB_REPORT_DEBOUNCE_MS);
}

async function reportTabs() {
  if (!paired) return;
  const tabs = await chrome.tabs.query({});

  const payload = tabs
    .filter((tab) => {
      if (typeof tab.id !== 'number') return false;
      // Report what the user could plausibly want to adjust: anything making sound, anything
      // already adjusted, and anything muted.
      const gain = tabGains.get(tab.id);
      return tab.audible || tab.mutedInfo?.muted || (gain !== undefined && gain !== 1);
    })
    .map((tab) => ({
      id: tab.id,
      title: tab.title || '',
      url: tab.url || '',
      audible: Boolean(tab.audible),
      muted: Boolean(tab.mutedInfo?.muted),
      volume: tabGains.get(tab.id) ?? 1,
      active: Boolean(tab.active),
      favicon: null,
    }));

  send({ type: 'tabs', tabs: payload });
}

// MARK: - Events

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'complete' || changeInfo.url) {
    reapply(tabId);
  }
  if (
    'audible' in changeInfo ||
    'mutedInfo' in changeInfo ||
    'title' in changeInfo ||
    'url' in changeInfo ||
    changeInfo.status === 'complete'
  ) {
    scheduleTabReport();
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabGains.delete(tabId);
  tabMutes.delete(tabId);
  send({ type: 'tabClosed', id: tabId });
});

chrome.tabs.onActivated.addListener(scheduleTabReport);
chrome.tabs.onCreated.addListener(scheduleTabReport);

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type === 'audify:requestGain') {
    // A freshly loaded frame asking what it should be playing at.
    const tabId = sender.tab?.id;
    respond({ gain: tabId === undefined ? 1 : tabGains.get(tabId) ?? 1 });
    return true;
  }
  if (message?.type === 'audify:status') {
    respond({
      connected: Boolean(socket && socket.readyState === WebSocket.OPEN),
      paired,
    });
    return true;
  }
  if (message?.type === 'audify:reconnect') {
    if (socket) socket.close();
    reconnectAttempts = 0;
    connect();
    respond({ ok: true });
    return true;
  }
  return false;
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.token || changes.port || changes.enabled) {
    if (socket) socket.close();
    reconnectAttempts = 0;
    connect();
  }
});

chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === KEEPALIVE_ALARM) connect();
});

chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
connect();
