// Audify Tab Volume — content script.
//
// Applies a gain to every media element in this frame. Runs in all frames so embedded players
// (YouTube embeds, ad iframes, chat widgets) are covered by the same control.
//
// Two mechanisms, chosen per element:
//
//   gain <= 1  →  `element.volume`. Never breaks playback, works with cross-origin media, and is
//                 what the browser itself uses.
//   gain > 1   →  a Web Audio GainNode, because `element.volume` cannot exceed 1.
//
// The split matters for correctness, not just simplicity: `createMediaElementSource` on media
// served without permissive CORS headers produces silence, so it is only used when the user has
// explicitly asked for more than 100% and there is no alternative.

(() => {
  const EPSILON = 0.001;
  let currentGain = 1;
  let audioContext = null;

  /** Elements already routed through a GainNode. */
  const routed = new WeakMap();
  /** Guards against reacting to volume changes we caused ourselves. */
  const applying = new WeakSet();

  function mediaElements() {
    return document.querySelectorAll('video, audio');
  }

  function ensureContext() {
    if (!audioContext) {
      audioContext = new (window.AudioContext || window.webkitAudioContext)();
    }
    if (audioContext.state === 'suspended') {
      audioContext.resume().catch(() => {});
    }
    return audioContext;
  }

  /// Routes an element through a GainNode so it can exceed 100%.
  ///
  /// Returns false when routing is impossible, in which case the caller falls back to clamping at
  /// 100% rather than risking silence.
  function route(element) {
    const existing = routed.get(element);
    if (existing) return existing;

    try {
      const context = ensureContext();
      const source = context.createMediaElementSource(element);
      const gainNode = context.createGain();
      source.connect(gainNode);
      gainNode.connect(context.destination);
      const node = { source, gainNode };
      routed.set(element, node);
      // The element's own volume becomes the page's business again; we control the node.
      setNativeVolume(element, 1);
      return node;
    } catch (error) {
      return null;
    }
  }

  function setNativeVolume(element, value) {
    applying.add(element);
    try {
      element.volume = Math.max(0, Math.min(value, 1));
    } catch (error) {
      // Some players expose a read-only volume; nothing useful to do.
    } finally {
      // Cleared on the next tick so the resulting 'volumechange' is recognised as ours.
      setTimeout(() => applying.delete(element), 0);
    }
  }

  function applyTo(element) {
    const node = routed.get(element);

    if (currentGain > 1 + EPSILON) {
      const target = node || route(element);
      if (target) {
        target.gainNode.gain.value = currentGain;
        return;
      }
      // Boost unavailable for this element: stay at full volume rather than going silent.
      setNativeVolume(element, 1);
      return;
    }

    if (node) {
      // Already routed from an earlier boost. Keep using the node — unrouting is not possible
      // once a MediaElementSource exists, and tearing it down would silence the element.
      node.gainNode.gain.value = currentGain;
      setNativeVolume(element, 1);
      return;
    }

    setNativeVolume(element, currentGain);
  }

  function applyAll() {
    mediaElements().forEach(applyTo);
  }

  function setGain(gain) {
    const next = Number(gain);
    if (!Number.isFinite(next)) return;
    currentGain = Math.max(0, Math.min(next, 5));
    applyAll();
  }

  // Messages from the service worker.
  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === 'audify:setGain') {
      setGain(message.gain);
    }
  });

  // Catches elements created after load, which is how every major streaming site works.
  // Listening in the capture phase means one listener covers the whole document.
  document.addEventListener('playing', (event) => {
    if (event.target instanceof HTMLMediaElement) applyTo(event.target);
  }, true);

  document.addEventListener('loadedmetadata', (event) => {
    if (event.target instanceof HTMLMediaElement) applyTo(event.target);
  }, true);

  // If the page sets its own volume, re-assert ours on top of it.
  document.addEventListener('volumechange', (event) => {
    const element = event.target;
    if (!(element instanceof HTMLMediaElement)) return;
    if (applying.has(element)) return;
    if (Math.abs(currentGain - 1) < EPSILON) return;
    applyTo(element);
  }, true);

  const observer = new MutationObserver((mutations) => {
    if (Math.abs(currentGain - 1) < EPSILON) return;
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node instanceof HTMLMediaElement) {
          applyTo(node);
        } else if (node instanceof Element) {
          node.querySelectorAll?.('video, audio').forEach(applyTo);
        }
      }
    }
  });

  const startObserving = () => {
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startObserving, { once: true });
  } else {
    startObserving();
  }

  // Ask what this frame's level should be — the service worker may have been restarted, or this
  // may be a new document in a tab that already had a level set.
  chrome.runtime.sendMessage({ type: 'audify:requestGain' }, (response) => {
    if (chrome.runtime.lastError) return;
    if (response && Number.isFinite(response.gain)) setGain(response.gain);
  });
})();
