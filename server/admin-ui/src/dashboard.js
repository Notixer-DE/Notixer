import { ref, computed, onMounted } from 'vue';

export function setupDashboard() {
  const authenticated = ref(false);
  const username = ref('admin');
  const loginForm = ref({ username: 'admin', password: '' });
  const loggingIn = ref(false);
  const loginError = ref('');

  const accounts = ref([]);
  const loading = ref(false);
  const creatingAccount = ref(false);
  const searchQuery = ref('');

  const createdDevice = ref(null);
  const pairingAccount = ref(null);

  function openPairing(account) {
    pairingAccount.value = account;
  }

  function closePairing() {
    pairingAccount.value = null;
    loadAccounts();
  }

  const showPasswordModal = ref(false);
  const pwdForm = ref({ current: '', new: '', repeat: '' });
  const pwdError = ref('');
  const savingPwd = ref(false);

  const toasts = ref([]);

  function showToast(message, type = 'success') {
    const id = Date.now() + Math.random();
    toasts.value.push({ id, message, type });
    setTimeout(() => {
      toasts.value = toasts.value.filter(t => t.id !== id);
    }, 3500);
  }

  async function checkAuth() {
    try {
      const res = await fetch('/admin/api/me');
      const data = await res.json();
      if (data.authenticated) {
        authenticated.value = true;
        username.value = data.username;
        loadAccounts();
      } else {
        authenticated.value = false;
      }
    } catch (e) {
      authenticated.value = false;
    }
  }

  async function login() {
    loginError.value = '';
    loggingIn.value = true;
    try {
      const res = await fetch('/admin/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(loginForm.value)
      });
      if (res.ok) {
        const data = await res.json();
        authenticated.value = true;
        username.value = data.username;
        loginForm.value.password = '';
        showToast('Signed in successfully');
        loadAccounts();
      } else {
        loginError.value = 'Invalid username or password.';
      }
    } catch (e) {
      loginError.value = 'Network error while signing in.';
    } finally {
      loggingIn.value = false;
    }
  }

  async function logout() {
    try {
      const res = await fetch('/admin/api/logout', { method: 'POST' });
      if (!res.ok) throw new Error('Sign out failed');
    } catch (e) {
      showToast('Could not sign out. Please try again.', 'danger');
      return;
    }
    authenticated.value = false;
    accounts.value = [];
    showToast('Signed out successfully');
  }

  async function loadAccounts() {
    loading.value = true;
    try {
      const res = await fetch('/admin/api/accounts');
      if (res.status === 401) {
        authenticated.value = false;
        return;
      }
      if (!res.ok) throw new Error('Could not load accounts');
      accounts.value = await res.json();
    } catch (e) {
      showToast('Could not load accounts. Please retry.', 'danger');
    } finally {
      loading.value = false;
    }
  }

  async function createAccount() {
    creatingAccount.value = true;
    try {
      const res = await fetch('/admin/api/accounts', { method: 'POST' });
      if (res.ok) {
        const data = await res.json();
        showToast(`New account ${data.id.substring(0, 8)}... created`);
        await loadAccounts();
      } else {
        showToast('Could not create the account', 'danger');
      }
    } catch (e) {
      showToast('Network error', 'danger');
    } finally {
      creatingAccount.value = false;
    }
  }

  async function deleteAccount(accountId) {
    if (!confirm(`Permanently delete the account "${accountId}"?\n\nAll associated notes, revisions and devices on the server will be permanently removed.`)) {
      return;
    }
    try {
      const res = await fetch(`/admin/api/accounts/${accountId}`, { method: 'DELETE' });
      if (res.ok) {
        showToast('Account deleted');
        await loadAccounts();
      } else {
        showToast('Could not delete the account', 'danger');
      }
    } catch (e) {
      showToast('Network error', 'danger');
    }
  }

  async function addDevice(accountId) {
    try {
      const res = await fetch(`/admin/api/accounts/${accountId}/devices`, { method: 'POST' });
      if (res.ok) {
        const data = await res.json();
        createdDevice.value = data;
        showToast('Device and access token generated!');
        await loadAccounts();
      } else {
        showToast('Could not add the device', 'danger');
      }
    } catch (e) {
      showToast('Network error', 'danger');
    }
  }

  async function revokeDevice(deviceId) {
    if (!confirm('Revoke this device? It will no longer be able to sync.')) {
      return;
    }
    try {
      const res = await fetch(`/admin/api/devices/${deviceId}/revoke`, { method: 'POST' });
      if (res.ok) {
        showToast('Device revoked');
        await loadAccounts();
      } else {
        showToast('Could not revoke the device', 'danger');
      }
    } catch (e) {
      showToast('Network error', 'danger');
    }
  }

  async function unrevokeDevice(deviceId) {
    try {
      const res = await fetch(`/admin/api/devices/${deviceId}/unrevoke`, { method: 'POST' });
      if (res.ok) {
        showToast('Device reactivated');
        await loadAccounts();
      } else {
        showToast('Could not reactivate the device', 'danger');
      }
    } catch (e) {
      showToast('Network error', 'danger');
    }
  }

  async function changePassword() {
    pwdError.value = '';
    if (pwdForm.value.new !== pwdForm.value.repeat) {
      pwdError.value = 'The new passwords do not match.';
      return;
    }
    savingPwd.value = true;
    try {
      const res = await fetch('/admin/api/change-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          current_password: pwdForm.value.current,
          new_password: pwdForm.value.new
        })
      });
      if (res.ok) {
        showToast('Password changed successfully');
        showPasswordModal.value = false;
        pwdForm.value = { current: '', new: '', repeat: '' };
      } else {
        pwdError.value = 'The current password is incorrect.';
      }
    } catch (e) {
      pwdError.value = 'Could not change the password.';
    } finally {
      savingPwd.value = false;
    }
  }

  function copyText(text, successMsg = 'Copied to clipboard!') {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => {
        showToast(successMsg);
      }).catch(() => {
        fallbackCopy(text, successMsg);
      });
    } else {
      fallbackCopy(text, successMsg);
    }
  }

  function fallbackCopy(text, successMsg) {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try {
      if (!document.execCommand('copy')) throw new Error('Copy failed');
      showToast(successMsg);
    } catch (e) {
      showToast('Could not copy. Select and copy the text manually.', 'danger');
    } finally {
      ta.remove();
    }
  }

  function formatBytes(bytes) {
    if (!bytes || bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function formatDate(dateStr) {
    if (!dateStr) return '-';
    try {
      const d = new Date(dateStr);
      return d.toLocaleString('en-GB', {
        day: '2-digit',
        month: '2-digit',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      });
    } catch (e) {
      return dateStr;
    }
  }

  const filteredAccounts = computed(() => {
    if (!searchQuery.value.trim()) return accounts.value;
    const q = searchQuery.value.toLowerCase().trim();
    return accounts.value.filter(a => a.id.toLowerCase().includes(q));
  });

  const totalDevices = computed(() => {
    return accounts.value.reduce((acc, a) => acc + (a.devices ? a.devices.length : 0), 0);
  });

  const activeDevices = computed(() => {
    return accounts.value.reduce((acc, a) => {
      return acc + (a.devices ? a.devices.filter(d => !d.revoked).length : 0);
    }, 0);
  });

  const revokedDevices = computed(() => {
    return totalDevices.value - activeDevices.value;
  });

  const totalUsedBytes = computed(() => {
    return accounts.value.reduce((acc, a) => acc + (a.used_bytes || 0), 0);
  });

  onMounted(() => {
    checkAuth();
  });

  return {
    authenticated,
    username,
    loginForm,
    loggingIn,
    loginError,
    accounts,
    loading,
    creatingAccount,
    searchQuery,
    createdDevice,
    showPasswordModal,
    pwdForm,
    pwdError,
    savingPwd,
    toasts,
    login,
    logout,
    loadAccounts,
    createAccount,
    deleteAccount,
    addDevice,
    pairingAccount,
    openPairing,
    closePairing,
    revokeDevice,
    unrevokeDevice,
    changePassword,
    copyText,
    formatBytes,
    formatDate,
    filteredAccounts,
    totalDevices,
    activeDevices,
    revokedDevices,
    totalUsedBytes
  };
}
