<script setup>
import { onUnmounted, ref } from 'vue';
import QRCode from 'qrcode';

const props = defineProps({ account: { type: String, required: true } });
const emit = defineEmits(['close']);
const server = ref(window.location.origin);
const recoveryKey = ref('');
const error = ref('');
const busy = ref(false);
const qr = ref('');
const request = new AbortController();
let expiry;

onUnmounted(() => {
  request.abort();
  clearTimeout(expiry);
  recoveryKey.value = '';
  qr.value = '';
});

function serverOrigin(value) {
  const url = new URL(value.trim());
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(loopback && url.protocol === 'http:')) ||
      url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Enter the HTTPS origin of your sync server, without a path.');
  }
  return url.origin;
}

async function generate() {
  busy.value = true;
  error.value = '';
  qr.value = '';
  clearTimeout(expiry);
  try {
    const origin = serverOrigin(server.value);
    const key = recoveryKey.value.trim();
    if (key && !/^[A-Za-z0-9_-]{43}=?$/.test(key)) {
      throw new Error('Enter a valid Notixer recovery key.');
    }
    const response = await fetch(`/admin/api/accounts/${props.account}/pairing`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
      signal: request.signal,
    });
    if (!response.ok) throw new Error('Could not create a pairing code. Reload the account and try again.');
    const invitation = await response.json();
    const payload = {
      v: 1, server: origin, account: invitation.account,
      code: invitation.code, needsKey: invitation.needs_key, ...(key && { key }),
    };
    const image = await QRCode.toDataURL('notixer-pair:' + JSON.stringify(payload), {
      errorCorrectionLevel: 'M', width: 420,
    });
    if (request.signal.aborted) return;
    qr.value = image;
    expiry = setTimeout(() => {
      qr.value = '';
      error.value = 'This pairing code has expired. Generate a new code to continue.';
    }, invitation.expires_in * 1000);
  } catch (cause) {
    if (!request.signal.aborted) error.value = cause instanceof Error ? cause.message : 'Could not generate the QR code.';
  } finally {
    recoveryKey.value = '';
    busy.value = false;
  }
}
</script>

<template>
  <div class="modal-backdrop" @keydown.esc="emit('close')">
    <section class="modal" role="dialog" aria-modal="true" aria-labelledby="pair-device-title">
      <h2 class="modal-title" id="pair-device-title">Pair a device</h2>
      <p class="modal-subtitle">In Notixer, open Sync settings and choose Scan pairing QR code.</p>
      <p v-if="error" class="error-msg" role="alert">{{ error }}</p>
      <template v-if="qr">
        <img class="pairing-qr" :src="qr" alt="One-time Notixer device pairing QR code">
        <p class="modal-subtitle">The code expires in five minutes and can pair one device. Keep it private.</p>
        <button class="btn btn-primary" @click="emit('close')">Done</button>
      </template>
      <form v-else @submit.prevent="generate">
        <div class="form-group">
          <label class="form-label" for="pair-server">Sync server address</label>
          <input id="pair-server" v-model="server" type="url" class="form-control" required :disabled="busy">
        </div>
        <div class="form-group">
          <label class="form-label" for="pair-key">Recovery key (optional)</label>
          <input id="pair-key" v-model="recoveryKey" type="password" class="form-control"
            autocomplete="off" spellcheck="false" :disabled="busy" aria-describedby="pair-key-help">
          <p class="modal-subtitle" id="pair-key-help">
            For an existing vault, paste its recovery key to include it in the QR code.
            The dashboard uses it only on this device. You can also enter it in Notixer after scanning.
          </p>
        </div>
        <div class="pairing-actions">
          <button class="btn btn-outline" type="button" @click="emit('close')">Cancel</button>
          <button class="btn btn-primary" type="submit" :disabled="busy">{{ busy ? 'Generating…' : 'Generate QR code' }}</button>
        </div>
      </form>
    </section>
  </div>
</template>
