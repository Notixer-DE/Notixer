# Notixer

Notixer is an offline-first notes and knowledge management app for Android, Linux and Windows. It combines handwriting, PDF annotations, Markdown, quick to-dos and study tools, with optional self-hosted end-to-end encrypted sync.

**Platforms:** Android 8 or later (API 26), Debian 13 (amd64), and Windows (x64).

> [!NOTE]
> This project was developed with AI assistance. Review the code, features and configuration before relying on it for production use. Keep external backups of important notes.

## Library and workspace

- Create multipage notebooks with blank, ruled or grid paper; import PDFs; create Markdown text notes and checklists.
- Select **To-do list** when creating a note to open a dedicated task editor. Type a task and press Enter or tap **Add task**. Check off tasks in the list or in Knowledge Hub. Export the list as a `.noter` file to reopen it as a to-do list.
- Use **New note** or **Import file** above the library list. Open **Show folders** to browse folders, filter by tag or manage folders. The list/grid toggle is next to the title search. Find **Search PDFs**, **Study today**, **Trash** and **Sync settings** under **Library actions**.
- Keep several documents open in tabs. Hide or show the tab strip without closing documents or losing their state. Use the restore button or **Ctrl+Alt+T** (**Cmd+Alt+T** on macOS).
- Open two views side by side or stacked, including two views of the same note. Each view keeps its own navigation position.
- Android starts with editor toolbars hidden. The toolbar toggle remains available to return to the full workspace.

## Handwriting and PDF editing

- Draw using a pressure-sensitive stylus, a desktop mouse, or optional finger drawing. Hold the stylus side button to erase temporarily, then release it to return to the selected tool.
- Use three customizable pen presets, a freehand highlighter, straight strokes, fixed or pressure-sensitive widths, point erasing and whole-stroke erasing.
- Open **Tool settings** to change color, stroke width, opacity, pressure behavior, eraser diameter and eraser mode. Eraser diameter is independent of pen width and also applies to the stylus side button.
- Use the lasso to select handwriting and PDF annotations together. Drag inside the selection to move it, use corner or edge grips to resize, and use the rotation grip to rotate. Each completed gesture is one undo step; cancelled gestures preserve the original content. **Transform selection** also accepts exact scale and angle values.
- Insert text and PNG/JPEG images. Select PDF text and highlight, underline or strike it through.
- Use bookmarks, PDF outlines, full-text PDF search, page duplication/reordering/copying, and custom page templates.
- Single-page view fits an unzoomed page initially. A manually chosen zoom is retained when moving to the next or previous page. Mouse/trackpad scrolling stays within the active page; use page controls or a horizontal touch swipe at fit zoom to change pages.
- The writing magnifier provides a second view over the original page.

Open **Settings → Keyboard shortcuts** to change tool and navigation bindings. The defaults are **Ctrl+Alt+D** for the pen, **Ctrl+Alt+H** for the highlighter, **Ctrl+Alt+E** for the eraser, and **Ctrl+Page Down / Page Up** for the next or previous page. Tooltips show the assigned keys.

## Markdown

- Switch between editable CommonMark/GFM source and a formatted reading view with interactive checklists.
- Use **Markdown** to edit the title or source. Links to Markdown notes open **Formatted**, including links to headings. Checklist boxes remain interactive in the formatted view.
- **Tab** inserts four spaces, or indents all selected lines. **Shift+Tab** removes one indentation level. Selection direction and existing line endings are preserved.
- In both source and formatted Markdown views, **Ctrl+Plus**, **Ctrl+Minus**, and **Ctrl+0** enlarge, reduce or reset the font. Number-pad equivalents and Cmd shortcuts are supported. Toolbar controls offer the same actions. The formatted view also supports two-finger pinch zoom. Each view retains its own zoom level; zoom does not change note contents.
- Insert inline code or fenced code blocks. The code-block action safely wraps selections that already contain backticks.
- Use **Insert link** to link entire files, headings in this note or another Markdown note, or a specific PDF page. Examples: `[Section](#study-plan)`, `[Other section](notes.md#study-plan)`, `[PDF page](reference.pdf#page=12)`. PDF page numbers start at 1. Duplicate heading names receive suffixes such as `-1`.
- Open **Graph view** from library actions or the Markdown editor's **Note actions** menu. Pan and zoom connections between files, search to highlight names, tap a file to open it, or tap a tag to focus its files. Search and graph options are available from the app bar; **Show tags** in **Graph options** toggles tag nodes. Multiple heading/page links to one file share a single connection; external links and embedded images are excluded.
- Assign tags through **Folders and tags** in a file's library menu or the Markdown editor's **Note actions** menu. Tag names are matched without case differences. Automatic backlinks remain available in Markdown notes.
- Embed local PNG/JPEG/WebP/GIF images and attach local audio/video files. On Android, the image/media attachment menu can take a photo, record video or record a voice message. Import/export individual `.md` files or linked collections as ZIP archives. External images are not downloaded automatically.

## Knowledge hub, journals and tasks

Open **Knowledge hub** from the library toolbar or a Markdown note's **Note actions** menu.

- **Search** searches Markdown content and PDF text with snippets. Results open at the matching source line or PDF page. Combine text, file type, folder, tag and open-task filters; save combinations in **Views**. Searches run file by file with background text/PDF processing and can be cancelled after the current file finishes. PDF matches are limited to 50 per file with an explicit warning. Image-only scans require an existing PDF text layer; this is not OCR.
- **Tasks** shows open quick to-dos and unchecked Markdown checkboxes, including journal entries. Tap a checklist task to open its source line, or check it off directly.
- Use **Add to-do** in the library or Knowledge Hub to add an item to a shared collection under **Tasks → Unsorted**. The default shortcut is **Ctrl+Alt+N**. Earlier quick to-dos stored as single-checkbox files are copied into the collection with their status, project and due date. Their original files move to local Trash. Quick to-do files with custom content are kept in the library.
- In **Tasks**, use **Today**, **Unsorted**, **Projects**, or **All tasks**. Open **Plan to-do** to edit a quick to-do, assign it to a project folder or set a due date. **Today** shows open to-dos due today or overdue, with the oldest due dates first. Checklists in other notes appear in **All tasks**.
- **Journal** provides one Markdown note per local calendar date, with Today, previous/next day and a date picker. Open an existing day or create it using the selected default template. Choose that template using **Journal template** beside the day actions. Entries are ordinary portable Markdown notes and participate in search, links, tags, backlinks and the graph. Applying a new default never replaces existing journal content.
- **Templates** creates, edits and deletes reusable Markdown text templates. Supported placeholders are `{{date}}` (YYYY-MM-DD), `{{weekday}}`, `{{year}}` and `{{title}}`. A Markdown note's menu can save its source as a template or insert a rendered template at the cursor. Journal templates are chosen from the same collection; image attachments are not copied into text templates.
- **Inbox** lists quick captures. Use **Quick capture** to save text or Markdown before organizing it with folders and tags. Android's Share sheet accepts shared text and URLs into the same capture dialog.
- **Tags** renames tags, merges them case-insensitively, or removes a tag from every file. Corresponding saved-view filters are updated too.

Type `[[` in Markdown source for file suggestions, or `[[File title#` / `[[#` for heading suggestions. Arrow keys select, Enter inserts, and Escape dismisses suggestions. Completion inserts standard relative Markdown links, which remain stable when titles change. Literal `[[Title]]`, `[[Title#Heading]]` and `[[Title|Label]]` also render as wiki links, resolving only unique file titles; code examples stay literal. Literal title links need an unambiguous current title.

Use **Outline** in a Markdown note's menu to jump to a heading. Opening the graph from a note starts a **Local graph** showing its direct connections; switch to the full graph or choose another focus file. Select PDF text and choose **Create linked source note** to capture the quotation in Markdown with a return link to its page and searchable passage.

### Library backups

**Backups** creates complete checksummed snapshots of notes (including ink, attachments, tags and study state), Markdown templates, saved views and PDF templates. Automatic backups are enabled by default: while the app is running, a first check occurs after 30 seconds and further checks every 15 minutes, saving only changed nonempty libraries. The latest seven snapshots are retained locally, and the backup screen reports the last automatic result. Automatic scheduling is not an Android background service.

Export snapshots to separate storage through the system save dialog. Local snapshots alone do not protect against device loss. Restore validates archive paths, checksums and notebook payloads before importing, then adds namespaced copies; existing notes remain intact and relative links within the restored collection keep working. Templates and views are merged. Library backups are limited to 512 MB; credentials and sync secrets are excluded. Saved views, text templates and journal preferences also participate in full-library sync.

## Study covers and spaced repetition

Draw rectangular covers over questions or answers, then reveal them in study mode.

**Study today** gathers new and due covers from local notes. Reveal an answer before rating it:

| Rating | Next review |
| --- | --- |
| Forgot | 10 minutes |
| Unsure | 1 day |
| Remembered | Double the previous interval, starting at 1 day, up to 180 days |

After a successful save, reviewing advances to the next due cover. The global study queue can continue into another note. If saving fails, the current review stays open so you can retry. Assessments are stored locally and merged during sync; revealed answers are private to each view.

## Templates

Save a page or an entire notebook as a local template. Cornell notes, Meeting and Weekly planner are included as starter templates. Each use creates an independent copy without folder, tags or study progress. Custom templates participate in full-library sync. Built-in starter templates are supplied with the app on every device.

## Saving, export and recovery

- Changes are saved atomically. **Ctrl+S** saves manually; **Ctrl+Z** and **Ctrl+Shift+Z** undo and redo.
- Export PDFs with or without study covers. Export complete `.noter` backups containing the document, handwriting, images, covers, tags, folder name and study history.
- Deleted notes first go to local trash. Previous versions are kept in bounded local history (at most 20 versions / 512 MiB per note). Restoring creates a new note. Trash and local history do not replace external backups.
- Linux app data stays at `~/.local/share/de.noter.noter/notebooks/`. Android uses private app storage. Export `.noter` backups before uninstalling or changing devices.
- Limits: document import 256 MB; image import 32 MB; Markdown source 4 MiB; text notes with attachments 64 MiB; ZIP import/export 128 MiB / 1,000 files. Password-protected PDFs, OCR and handwriting recognition are not supported.
- The English-language update preserves existing storage paths, JSON keys, archive versions and legacy PDF study-cover identifiers. Existing note titles, folder names, tags, saved preset names and note contents are user data and are not translated automatically.

## Optional end-to-end encrypted sync

Notixer works completely offline. The cloud button can connect a self-hosted Notixer server running Rust/Loco and PostgreSQL with Docker Compose.

- Note contents, titles, tags, folder names and study history are encrypted on the device. The recovery key stays on your devices. Without the key or a configured device, server data cannot be recovered.
- Concurrent document/template edits become conflict copies. Full-library sync includes quick to-dos, custom PDF and Markdown templates, journal settings, saved views, empty folders, pen presets, drawing choices, reading positions and persistent sidebar/Markdown zoom preferences. Independent settings merge per key; concurrent values are preserved in visible settings conflict notes. Account credentials, OS permissions, local trash, local version history and automatic backup files remain device-specific. Selecting one note still syncs only that note.
- Quick to-do backups and sync include completed items. Sync merges separate to-dos by ID. Update the app on each connected device before syncing the new collection.
- See [Self-hosted sync server](docs/sync-server.md) for setup and operation.

## Install and build

Download Android APKs, Debian packages, Windows ZIPs and checksums from [GitHub Releases](https://github.com/Notixer-DE/Notixer/releases/latest).

Use Flutter **3.44.0** / Dart **3.12**:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tools
flutter analyze
flutter test
# Optional dashboard behavior checks (Node.js):
node tools/test-admin-ui.cjs
```

### Android

Requires Java 21 and Android SDK 36:

```sh
flutter build apk --release
# Or package the APK under dist/:
bash tools/build-android.sh
```

The packaging script writes `dist/notixer_<version>_preview.apk`. The release APK retains the Android application ID so existing installations can update in place.

### Debian 13 (amd64)

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
bash tools/build-deb.sh
sudo apt install ./dist/notixer_1.3.0_amd64.deb
```

Installing the `notixer` package replaces the previous `noter` package and keeps the existing notebooks. Launch it from the app menu or run `notixer`.

### Windows (x64)

Generate the Windows runner from a clean checkout.

```powershell
./tools/generate-windows-runner.ps1
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
```

The runner builds `build/windows/x64/runner/Release/notixer.exe`.

### Performance probes

```sh
python3 tools/performance.py
python3 tools/ink_performance.py
python3 tools/markdown_scroll.py
```

These are headless CPU/event-loop probes, not device GPU or frame-rate guarantees. See the [UX and code audit](docs/ux-code-audit.md) for the scope, changes and remaining limitations of the English-language overhaul.

Desktop library and Markdown navigation sidebars can be hidden and restored using the sidebar button. The PDF page overview has its own toggle.


### Media library

Choose **New note → Add media** to add images, videos or audio to the current folder and tag filter. Existing files can be imported on Android, Windows and Linux. Android additionally provides **Take photo**, **Record video** and **Record voice message**. Microphone access is requested only when recording starts. Cancel discards the recording; **Stop and add** stores it. Recording stops when the app enters the background, and is limited to ten minutes. Failed saves retain the pending import with a retry action. **Recover captured media** exposes captures left unfinished by a camera/app restart; imports can be retried or discarded.

Images open in a zoomable viewer. Android plays voice/audio in the app with pause and seek controls and opens video in an in-app system player. Windows/Linux use the installed default media player. Format and codec support are device-dependent. Supported containers are PNG/JPEG/WebP/GIF, MP4/MOV/WebM, and M4A/MP3/WAV/Ogg/AAC/FLAC. Library media is limited to 128 MB per file; Markdown attachments are limited to 32 MB each and 64 MB per note. Markdown uses portable image syntax and ordinary audio/video attachment links; clicking an attachment opens its viewer/player. ZIP collection export includes referenced attachments and linked standalone media.

Media is stored in version-5 notebook archives and participates in tags, folders, sync, backups, history and trash recovery. Existing PDF/Markdown archives retain their previous formats. Update every connected device to a media-aware version before using the expanded library sync.

Sync reuses local winners instead of downloading unchanged payloads, transfers up to four encrypted blocks concurrently, validates and reuses downloaded blocks, and shares one revision-list snapshot across the document and preference phases. Attachment archives have deterministic timestamps so unchanged source/attachments do not create false revisions. Automatic preference sync checks a local fingerprint before processing payloads or discovering revisions; explicit full sync always checks remote changes.
