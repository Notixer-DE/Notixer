# Media and complete library sync

## Storage and capture

- Standalone media uses notebook archive version 5 with `paper: media:<extension>` and a `document.media` entry. Existing PDF and Markdown formats remain unchanged. Media uses the same catalog, sync, backup, trash and recovery paths as documents.
- Supported media containers are bounded at 128 MB. File signatures are checked before import; actual codec/decoding failures are reported by the image/audio/video viewer. Markdown attachments retain the existing 32 MB per asset and 64 MB per note limits.
- Android photo/video capture delegates to the installed camera with a private FileProvider output URI. URI-returning camera apps are supported too. No broad photo/storage permission is requested. Voice messages use AAC in an M4A container, with explicit runtime microphone consent, cancellation, a ten-minute limit and stop-on-background behavior.
- Captured temporary files are released after a successful durable save. A failed library save keeps the pending import and offers Retry. Captures interrupted by activity/app recreation remain available through Recover captured media. Playback uses owned native player sessions so closing one tab cannot stop a different tab's audio. Desktop audio/video uses the installed media player.
- Markdown stores images with portable image syntax and audio/video with ordinary local links. Referenced attachments and linked standalone media survive linked ZIP export/import.

## Sync scope and recovery

Full-library sync includes custom PDF/page/notebook and Markdown/journal templates, selected journal template, automatic-backup preference, saved views, empty folders, pen presets, last drawing tool/style, drawing policies, reading positions and persistent display preferences (library/Markdown sidebars and both Markdown zoom levels). Built-in starter templates ship with the app. Credentials, OS permissions, local backup files, trash and per-device recovery history stay local. One-note sync remains scoped to that note.

Templates and settings are staged as individual canonical records in a hidden `.sync-extras` repository. The existing encrypted revision, tombstone, compare-and-swap and deterministic conflict-copy protocol is reused. Normal document sync filters the reserved `extra_` namespace. Setting conflicts remain visible as ordinary Markdown conflict notes; template and saved-view conflicts preserve separate entries. Folder references in saved views travel by folder name and are mapped back to local IDs.

Incoming records are validated before preferences are applied. Unset optional values do not delete choices on other devices; corrupt optional files are sanitized/recovered without erasing remote preferences. Folder-name casing converges to the canonical revision. Source files are checked again after remote I/O; an external write aborts application. If application fails, staging baselines are rewound so a retry still recognizes concurrency rather than treating an unapplied remote revision as its local baseline. Update every connected device before using this expanded sync namespace and media format.

## Efficiency

- Reuse a matching local winner instead of downloading a payload just uploaded or already present. A settled unchanged head requires no payload transfer.
- Share one account/revision-discovery snapshot across document and settings phases.
- Upload/download at most four blocks concurrently; append downloaded plaintext in manifest order and deduplicate repeated block fetches within a batch.
- Verify ciphertext hashes and AEAD before reuse, including local downloaded-block cache entries; corrupt caches refetch, and corrupt server blocks fail without replacing documents.
- Stable attachment ZIP timestamps prevent false changes when identical Markdown is repackaged later.
- Automatic preference sync uses an account-scoped local fingerprint to skip unchanged payload processing and revision discovery. Explicit full sync always checks remote revisions. Unchanged template/preference files are not rewritten unnecessarily, and reading valid cached blocks does not rewrite their cache files.

## Validation

Tests cover media archive/backup/sync/recovery and linked bundle round trips; two-device settings/templates, independent edits, deletions, concurrent conflicts, external-write retries, unchanged syncs separated in real time, discovery/payload call counts, five-block transfer concurrency bounded at four requests, exact reassembly, verified cache reuse and corrupt ciphertext. Responsive widget tests open images as workspace tabs on phone and desktop. Actual UI captures include desktop, phone portrait/landscape and 200% system text. Native camera, microphone and codec behavior still needs verification on physical Android devices; CI compiles the Android bridge and builds the signed APK.
