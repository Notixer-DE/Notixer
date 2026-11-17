# UX and code audit

This review covers the Flutter library, PDF and Markdown editors, drawing tools, study workflow, local storage and recovery, synchronization, packaging scripts and the self-hosted admin dashboard. The review and English-language overhaul are based on `0cbcf5d` (the merged Markdown/ink fixes).

## Findings and changes

| Area | Finding | Change |
| --- | --- | --- |
| Eraser | The application used an eraser radius internally but exposed only pen width. | Added a separately labelled eraser diameter slider (4–80 pt), using the existing persisted PDF preference. It also controls the stylus side button. Pen width is unchanged. |
| Document tabs | The tab strip could not be hidden even in a focused editor. | Added Hide/Show document tabs and Ctrl/Cmd+Alt+T. Editors remain mounted; hiding tabs does not close notes, save over undo state, or reset zoom. A restore control remains available. |
| Lasso and mixed selections | Fine positioning, scaling and rotation required button clusters; ink had separate per-stroke boxes. | Added a shared frame with move, edge/corner resize and rotation targets, each with a 44px hit area. Ink previews during gestures. Mixed PDF changes commit on release with one shared anchor and one undo transaction. Escape and pointer cancellation preserve originals. Minimum frame dimensions keep grips from obscuring the movement target on a thin stroke. Exact numeric transformations remain available. |
| Single-page navigation | Every page jump refitted the page, discarding a manually chosen zoom. | Initial fitting and normal navigation are separate. Fit-mode browsing still fits mixed-size pages; manually chosen zoom is retained between pages. Viewport resizing can refit the page. |
| Single-page scrolling | The underlying continuous list could scroll away from the pinned page while frame corrections moved it back. Corrections also applied the same matrix twice unnecessarily. | Resolve wheel scrolling before the continuous list and clamp it to the active page. Avoid redundant matrix updates and avoid corrective panning during an active touch drag. Keep native Ctrl/Cmd+wheel zoom and pinch input. Regression captures check painted page corners after vertical and horizontal panning. |
| Review workflow | Rating a cover left the user on the same answer. | After a successful save, advance to the next due cover. The Study today queue continues into another note. Save failure prevents advancement. An explicit Next due cover control is available within a note. |
| Markdown editing | Font size was fixed while editing. | Added source zoom via Ctrl/Cmd+Plus, Minus and 0, number-pad keys and toolbar controls. Zoom is local presentation state and does not modify note contents or reset when switching views. |
| Localization | German application text, generated templates, errors and server administration were mixed with English developer terminology. | Switched the app and native editor localization to English, translated UI/semantics/tooltips/errors/default content, and updated documentation, release notes, packaging and preview fixtures. |
| Dates | Library timestamps hard-coded German day.month.year formatting. | Use Material localizations, consistent with the English application locale. |
| Preset import | NaN/infinite width or opacity could bypass numeric bounds checks; color/name validation differed from the editor. | Validate finite numeric values, the ARGB range and the UI name limit before accepting a preset. |
| Library lifecycle | Startup could resume an async action after the library widget was disposed. | Guard the async startup continuation and action entry/continuation with mounted checks. |
| Admin feedback | Failed account loads and failed clipboard fallbacks could be silent or report success; failed logout still changed the local UI to signed out. | Report account-load/copy failures, always clean up temporary clipboard elements, and only show a successful sign-out after the server accepts it. |
| Obsolete UI/build paths | Per-stroke selection boxes, duplicate movement/resize/rotation button groups, a repeated busy guard and a Google Drive-specific build cache fallback remained. | Removed these paths and extracted selection interactions into a dedicated widget. |

## Compatibility deliberately retained

- Application/package IDs, Linux data directories, file extensions, archive versions, JSON keys, encryption inputs and sync identifiers are unchanged.
- The legacy PDF study-cover marker `Noter:Lernabdeckung:v1` stays byte-for-byte intact. It is a persisted format identifier, not interface text.
- Existing user-created note contents, titles, tags, folder names, templates and pen preset names are not rewritten or translated.
- Legacy PDF-embedded handwriting, pressure recovery, point/whole-stroke erasing and page-copy conversion remain supported. These paths are compatibility code, not dead code.
- Unicode test fixtures intentionally retain non-English sample data to exercise title/heading encoding and round trips.
- Vendored Vue is retained for offline administration, with its existing license notices.

## Verification

The repository includes regression tests for eraser settings, tab state, direct selection gestures and cancellation, anisotropic mixed transformations, single-page zoom retention and edge scrolling, pixel captures of panned PDFs, saved study progression, Markdown zoom, and invalid preset import. Existing import/export, recovery, sync, touch, handwriting, Markdown and responsive-layout tests are also part of the validation.

Real Flutter widgets are rendered at desktop, tablet and phone sizes by `tools/design_preview.py`. Headless PDF/ink/Markdown probes measure event-loop/CPU behavior rather than physical-device frame rates.

### Final validation results

- Flutter 3.44.0 / Dart 3.12: **252 tests passed**, with one existing live-server test skipped because no server endpoint was configured.
- `flutter analyze --no-pub`: no issues.
- `dart format --output=none --set-exit-if-changed lib test tools`: no changes required.
- `node tools/test-admin-ui.cjs`: passed using the actual dashboard script with mocked network/clipboard failures.
- PDF event-loop, independent ink and long-Markdown probes: passed. Saving the 48-MiB fixture stayed below the repository's 250-ms event-loop guard; these results are not device frame-rate claims.
- Desktop, tablet and phone application screenshots: rendered successfully and visually reviewed at representative sizes.
- Shell syntax checks for packaging scripts and Python byte-compilation: passed.
- Rust server compilation, container integration and Android/Windows release packaging were not run locally in this environment. The existing CI jobs remain responsible for these checks.

## Remaining boundaries

- During a mixed transformation, vector ink and the shared frame preview continuously; PDF annotation appearances are updated when the gesture commits. Re-rendering the PDF for every pointer sample would undermine drawing responsiveness.
- Direct grips do not flip a selection through zero size. Scaling is bounded and remains positive; larger exact changes can use the numeric dialog.
- Tab visibility and Markdown font zoom are workspace/editor state, not synced document data. The eraser setting uses the existing device preference store.
- Larger editor and storage classes still contain substantial compatibility and coordination logic. A broad rewrite or deletion was avoided while making behavioral changes; the new grip UI is separated from document storage and undo logic.
- Headless tests and screenshots do not replace Android stylus hardware, GPU/driver, Windows packaging or real-server deployment testing.
