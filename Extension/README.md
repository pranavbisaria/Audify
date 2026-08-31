# Audify Tab Volume

Chromium extension that gives the Audify macOS app control over individual browser tabs.

Works in Chrome, Edge, Brave, Vivaldi, Arc, Opera and other Chromium browsers (116 or newer).

## Install

1. Open `chrome://extensions` and turn on **Developer mode** (top right).
2. Click **Load unpacked** and select this folder.
   Inside an installed Audify, it lives at
   `/Applications/Audify.app/Contents/Resources/Extension`.
3. Click the Audify icon in the browser toolbar.
4. Paste the pairing code from **Audify ▸ Settings ▸ Browser** and press **Connect**.

The badge shows the state: green dot for connected, `!` for a pairing problem, `off` when disabled.

Once connected, you control tabs from the **Audify menu bar icon**, not from this popup. The popup
only handles pairing.

## How it connects

The extension opens a WebSocket to `ws://127.0.0.1:17843` and must present the pairing code before
Audify accepts anything. The listener is bound to the loopback interface, so nothing outside your
Mac can reach it. The port is configurable at both ends.

Native messaging was the other option, and was rejected: it would have Chrome spawn a helper
process that then needs its own channel into the running menu bar app. A loopback socket keeps it to
one hop, behaves the same across every Chromium browser, and survives the app and the browser
restarting in either order.

## How volume is applied

| Requested level | Mechanism | Notes |
|---|---|---|
| Mute | `chrome.tabs.update({muted})` | Native, instant, works even on pages where scripts cannot run |
| 0–100% | `element.volume` | Never breaks playback; works with cross-origin media |
| 100–200% | Web Audio `GainNode` | The only way past 100%; see caveat |

The content script runs in **all frames**, so audio inside embedded players and iframes is covered
by the same control.

The split between the two volume mechanisms is about correctness, not convenience:
`createMediaElementSource` on media served without permissive CORS headers produces *silence*, so
it is only used when you explicitly ask for more than 100%. If routing fails for an element, that
element stays at 100% instead of going quiet.

## Troubleshooting

**Badge shows `!`** — the pairing code does not match. Copy it again from Audify ▸ Settings ▸
Browser. The popup shows the exact reason Audify gave.

**Badge is grey / not connected** — check Audify is running and that *Control individual browser
tabs* is on in its Browser settings. The extension retries with backoff and revives itself once a
minute, so it reconnects on its own once the app is available.

**A tab's slider does nothing** — the page is probably generating audio through the Web Audio API
rather than a media element. Mute still works for that tab, and so does turning the whole browser
down from the Apps section of the Audify menu.

**Nothing appears under Browser Tabs** — only tabs that are making sound, are muted, or have
already been adjusted are listed. Start playback and the tab appears.

## Files

```
manifest.json    MV3 manifest
background.js    Service worker: bridge connection, tab enumeration, routing
content.js       Applies gain to media elements, in every frame
popup.html/js    Pairing UI
```

## Permissions used

- `tabs` — read tab titles and audible state, and mute tabs natively.
- `storage` — remember the pairing code and port.
- `alarms` — revive the service worker after MV3 evicts it.
- `<all_urls>` — the content script must run wherever audio can play.

No data leaves your machine. The only network connection is to `127.0.0.1`.
