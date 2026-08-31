// Pairing UI. All the actual volume control lives in the Audify app's menu bar popover.

const dot = document.getElementById('dot');
const stateLabel = document.getElementById('state');
const statusLabel = document.getElementById('status');
const tokenField = document.getElementById('token');
const portField = document.getElementById('port');
const saveButton = document.getElementById('save');
const toggleButton = document.getElementById('toggle');

const DEFAULT_PORT = 17843;

async function load() {
  const stored = await chrome.storage.local.get(['token', 'port', 'enabled', 'lastError']);
  tokenField.value = stored.token || '';
  portField.value = stored.port || DEFAULT_PORT;
  const enabled = stored.enabled !== false;
  toggleButton.textContent = enabled ? 'Disable' : 'Enable';

  chrome.runtime.sendMessage({ type: 'audify:status' }, (response) => {
    if (chrome.runtime.lastError || !response) {
      render(enabled, false, false, stored.lastError);
      return;
    }
    render(enabled, response.connected, response.paired, stored.lastError);
  });
}

function render(enabled, connected, paired, lastError) {
  dot.className = 'dot';
  if (!enabled) {
    dot.classList.add('warn');
    stateLabel.textContent = 'Disabled';
    statusLabel.textContent = '';
    return;
  }
  if (paired) {
    dot.classList.add('ok');
    stateLabel.textContent = 'Connected to Audify';
    statusLabel.textContent = 'Adjust tabs from the Audify menu bar icon.';
    return;
  }
  if (connected) {
    dot.classList.add('warn');
    stateLabel.textContent = 'Connected, waiting to pair';
    statusLabel.textContent = 'Check the pairing code matches Audify ▸ Settings ▸ Browser.';
    return;
  }
  dot.classList.add('bad');
  stateLabel.textContent = 'Not connected';
  statusLabel.textContent = lastError
    ? lastError
    : 'Make sure Audify is running and "Control individual browser tabs" is on.';
}

saveButton.addEventListener('click', async () => {
  const token = tokenField.value.trim().toUpperCase();
  const port = Number(portField.value) || DEFAULT_PORT;
  await chrome.storage.local.set({ token, port, enabled: true, lastError: '' });
  chrome.runtime.sendMessage({ type: 'audify:reconnect' }, () => {
    setTimeout(load, 600);
  });
});

toggleButton.addEventListener('click', async () => {
  const stored = await chrome.storage.local.get(['enabled']);
  const enabled = stored.enabled !== false;
  await chrome.storage.local.set({ enabled: !enabled });
  setTimeout(load, 400);
});

tokenField.addEventListener('input', () => {
  // Keep the field looking like the code shown in the app.
  const raw = tokenField.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 12);
  tokenField.value = raw.replace(/(.{4})(?=.)/g, '$1-');
});

load();
