<script>
import { setupDashboard } from './dashboard.js';
import PairDeviceDialog from './PairDeviceDialog.vue';

export default {
  components: { PairDeviceDialog },
  setup: setupDashboard,
};
</script>

<template>
<div class="dashboard">
    <!-- Header -->
    <header>
      <div class="brand">
        <div class="brand-icon">N</div>
        <span>Notixer Sync Server</span>
      </div>
      <div class="user-nav" v-if="authenticated">
        <div class="user-badge">
          <span>Signed in as</span>
          <strong>{{ username }}</strong>
        </div>
        <button class="btn btn-outline btn-sm" @click="showPasswordModal = true">
          Change password
        </button>
        <button class="btn btn-danger btn-sm" @click="logout">
          Sign out
        </button>
      </div>
    </header>

    <!-- Login View -->
    <div class="main-container" v-if="!authenticated">
      <div class="login-container">
        <h2 style="font-size: 1.4rem; font-weight: 700; margin-bottom: 0.5rem;">Administration Login</h2>
        <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 1.5rem;">
          Sign in to manage accounts and device access tokens.
        </p>

        <div class="error-msg" v-if="loginError">
          {{ loginError }}
        </div>

        <form @submit.prevent="login">
          <div class="form-group">
            <label class="form-label">Username</label>
            <input type="text" class="form-control" v-model="loginForm.username" required autocomplete="username" autofocus>
          </div>
          <div class="form-group">
            <label class="form-label">Password</label>
            <input type="password" class="form-control" v-model="loginForm.password" required autocomplete="current-password">
          </div>
          <button type="submit" class="btn btn-primary" style="width: 100%; margin-top: 0.5rem;" :disabled="loggingIn">
            {{ loggingIn ? 'Sign in...' : 'Sign in' }}
          </button>
        </form>

        <div style="margin-top: 1.5rem; text-align: center; font-size: 0.8rem; color: var(--text-muted); background: rgba(255,255,255,0.03); padding: 0.75rem; border-radius: 8px;">
          Initial default credentials: <strong>admin</strong> / <strong>admin</strong>
        </div>
      </div>
    </div>

    <!-- Authenticated Dashboard -->
    <div class="main-container" v-else>
      <!-- Quick Stats -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-title">Registered accounts</div>
          <div class="stat-value">{{ accounts.length }}</div>
          <div class="stat-sub">Active user accounts</div>
        </div>
        <div class="stat-card">
          <div class="stat-title">Total devices</div>
          <div class="stat-value">{{ totalDevices }}</div>
          <div class="stat-sub">{{ activeDevices }} active / {{ revokedDevices }} revoked</div>
        </div>
        <div class="stat-card">
          <div class="stat-title">Storage used</div>
          <div class="stat-value">{{ formatBytes(totalUsedBytes) }}</div>
          <div class="stat-sub">Note blobs and manifests</div>
        </div>
      </div>

      <!-- Action & Search Bar -->
      <div class="action-bar">
        <div style="display: flex; gap: 0.75rem; align-items: center;">
          <button class="btn btn-primary" @click="createAccount" :disabled="creatingAccount">
            + Create account
          </button>
          <button class="btn btn-outline" @click="loadAccounts" :disabled="loading">
            Refresh
          </button>
        </div>
        <input
          type="text"
          class="search-input"
          placeholder="Filter by account ID..."
          v-model="searchQuery"
        >
      </div>

      <!-- Loading Indicator -->
      <div v-if="loading && accounts.length === 0" style="text-align: center; padding: 3rem; color: var(--text-muted);">
        Loading accounts...
      </div>

      <!-- Empty State -->
      <div v-else-if="filteredAccounts.length === 0" style="text-align: center; padding: 4rem 2rem; background: var(--card-bg); border-radius: 12px; border: 1px dashed var(--card-border);">
        <p style="color: var(--text-muted); font-size: 1rem; margin-bottom: 1rem;">
          {{ searchQuery ? 'No accounts match your search.' : 'No accounts on this server yet.' }}
        </p>
        <button class="btn btn-primary" @click="createAccount" v-if="!searchQuery">
          Create your first account
        </button>
      </div>

      <!-- Account List -->
      <div v-else>
        <div class="account-card" v-for="acc in filteredAccounts" :key="acc.id">
          <!-- Card Header -->
          <div class="account-header">
            <div class="account-title-group">
              <span class="uuid-tag">
                {{ acc.id }}
                <button class="copy-btn" title="Copy UUID" @click="copyText(acc.id, 'Account UUID copied')">
                  📋
                </button>
              </span>
              <span class="badge badge-success" v-if="acc.needs_key">
                E2EE confirmed
              </span>
              <span class="badge badge-warning" v-else>
                Waiting for first sync
              </span>
            </div>

            <div class="account-meta">
              <div class="account-meta-item">
                Storage: <strong>{{ formatBytes(acc.used_bytes) }}</strong> / {{ formatBytes(acc.quota_bytes) }}
              </div>
              <div class="account-meta-item">
                Revisions: <strong>{{ acc.revision_count }}</strong>
              </div>
              <button class="btn btn-primary btn-sm" @click="openPairing(acc.id)">
                Pair device by QR code
              </button>
              <button class="btn btn-outline btn-sm" @click="addDevice(acc.id)">
                + Add device
              </button>
              <button class="btn btn-danger btn-sm" title="Permanently delete the account and all its data" @click="deleteAccount(acc.id)">
                Delete account
              </button>
            </div>
          </div>

          <!-- Card Body: Devices -->
          <div class="account-body">
            <div class="devices-header">
              <span class="devices-title">Linked devices ({{ acc.devices ? acc.devices.length : 0 }})</span>
            </div>

            <div v-if="!acc.devices || acc.devices.length === 0" style="color: var(--text-muted); font-size: 0.85rem; padding: 0.5rem 0;">
              No devices registered yet. Choose <em>Pair device by QR code</em> above to add a device.
            </div>

            <table class="device-table" v-else>
              <thead>
                <tr>
                  <th>Device ID</th>
                  <th>Registered on</th>
                  <th>Status</th>
                  <th style="text-align: right;">Action</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="dev in acc.devices" :key="dev.id">
                  <td>
                    <span class="device-id">
                      {{ dev.id }}
                      <button class="copy-btn" title="Copy device ID" @click="copyText(dev.id, 'Device ID copied')">
                        📋
                      </button>
                    </span>
                  </td>
                  <td>{{ formatDate(dev.created_at) }}</td>
                  <td>
                    <span class="badge badge-danger" v-if="dev.revoked">Revoked</span>
                    <span class="badge badge-success" v-else>Active</span>
                  </td>
                  <td style="text-align: right;">
                    <button
                      class="btn btn-danger btn-sm"
                      v-if="!dev.revoked"
                      @click="revokeDevice(dev.id)"
                    >
                      Revoke
                    </button>
                    <button
                      class="btn btn-outline btn-sm"
                      v-else
                      @click="unrevokeDevice(dev.id)"
                    >
                      Reactivate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>

    <!-- Device Created / Token Modal -->
    <div class="modal-backdrop" v-if="createdDevice" @click.self="createdDevice = null">
      <div class="modal">
        <h3 class="modal-title">Device and access token created</h3>
        <p class="modal-subtitle">
          Device ID: <code style="color: #38bdf8;">{{ createdDevice.id }}</code>
        </p>

        <div class="token-box">
          <div class="token-label">Device access token (Token):</div>
          <div class="token-value">{{ createdDevice.token }}</div>
        </div>

        <div class="alert-box">
          <strong>Important:</strong> For security, this access token is displayed <strong>only once</strong>!
          Copy it now and enter it in Notixer on the corresponding device. The server only stores a SHA-256 hash.
        </div>

        <div style="display: flex; justify-content: flex-end; gap: 0.75rem;">
          <button class="btn btn-outline" @click="createdDevice = null">
            Close
          </button>
          <button class="btn btn-primary" @click="copyText(createdDevice.token, 'Access token copied to clipboard!')">
            Copy token
          </button>
        </div>
      </div>
    </div>

    <!-- Change Password Modal -->
    <div class="modal-backdrop" v-if="showPasswordModal" @click.self="showPasswordModal = false">
      <div class="modal">
        <h3 class="modal-title">Change admin password</h3>
        <p class="modal-subtitle">Set a new, secure password for the user <strong>{{ username }}</strong>.</p>

        <div class="error-msg" v-if="pwdError">{{ pwdError }}</div>

        <form @submit.prevent="changePassword">
          <div class="form-group">
            <label class="form-label">Current password</label>
            <input type="password" class="form-control" v-model="pwdForm.current" required>
          </div>
          <div class="form-group">
            <label class="form-label">New password</label>
            <input type="password" class="form-control" v-model="pwdForm.new" required minlength="12">
          </div>
          <div class="form-group">
            <label class="form-label">Repeat new password</label>
            <input type="password" class="form-control" v-model="pwdForm.repeat" required minlength="12">
          </div>
          <div style="display: flex; justify-content: flex-end; gap: 0.75rem; margin-top: 1.5rem;">
            <button type="button" class="btn btn-outline" @click="showPasswordModal = false">Cancel</button>
            <button type="submit" class="btn btn-primary" :disabled="savingPwd">
              {{ savingPwd ? 'Save...' : 'Update password' }}
            </button>
          </div>
        </form>
      </div>
    </div>

    <!-- Toast Notifications -->
    <div class="toast-container">
      <div
        class="toast"
        :class="t.type === 'danger' ? 'toast-danger' : 'toast-success'"
        v-for="t in toasts"
        :key="t.id"
      >
        {{ t.message }}
      </div>
    </div>
    <PairDeviceDialog
      v-if="authenticated && pairingAccount"
      :account="pairingAccount"
      @close="closePairing"
    />
</div>
</template>
