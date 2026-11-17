# Notixer

An English-language, offline-first note-taking app with handwriting, PDF annotations, Markdown, study covers and optional end-to-end encrypted sync to a self-hosted server.

**Platforms:** Android 8 or later (API 26), Debian 13 (amd64), and Windows (x64).

> [!NOTE]
> This project was developed with AI assistance. Review the code, features and configuration before relying on it for production use. Keep external backups of important notes.

## Library and workspace

- Create multipage notebooks with blank, ruled or grid paper; import PDFs; create Markdown text notes and checklists.
- Organize notes with folders and tags. Combine title, type, folder and tag filters, and switch between list and grid layouts.
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

## Markdown

- Switch between editable CommonMark/GFM source and a formatted reading view with interactive checklists.
- **Tab** inserts four spaces, or indents all selected lines. **Shift+Tab** removes one indentation level. Selection direction and existing line endings are preserved.
- In source mode, **Ctrl+Plus**, **Ctrl+Minus**, and **Ctrl+0** enlarge, reduce or reset the editor font. Number-pad equivalents and Cmd shortcuts are supported. Toolbar controls offer the same actions. Font zoom does not change note contents.
- Insert inline code or fenced code blocks. The code-block action safely wraps selections that already contain backticks.
- Link notes using relative links such as `[Title](file.md)`, heading anchors and automatic backlinks.
- Embed local PNG/JPEG images. Import/export individual `.md` files or linked collections as ZIP archives. External images are not downloaded automatically.

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

Save a page or an entire notebook as a local template. Cornell notes, Meeting and Weekly planner are included as starter templates. Each use creates an independent copy without folder, tags or study progress. Templates are local and are not synced.

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
- Concurrent edits become conflict copies. Pen presets, templates, reading positions, trash and local version history are not synced.
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

### Debian 13 (amd64)

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
bash tools/build-deb.sh
sudo apt install ./dist/noter_1.3.0_amd64.deb
```

### Windows (x64)

```powershell
flutter create --platforms=windows --project-name noter .
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
```

### Performance probes

```sh
python3 tools/performance.py
python3 tools/ink_performance.py
python3 tools/markdown_scroll.py
```

These are headless CPU/event-loop probes, not device GPU or frame-rate guarantees. See the [UX and code audit](docs/ux-code-audit.md) for the scope, changes and remaining limitations of the English-language overhaul.
