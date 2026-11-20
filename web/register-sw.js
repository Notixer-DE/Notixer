'use strict';

if ('serviceWorker' in navigator) {
  // Use the release's manifest when checking for updates to unchanged filenames.
  navigator.serviceWorker.register('notixer-sw.js', {updateViaCache: 'none'})
    .catch(error => console.warn('Notixer offline setup failed:', error));
}
