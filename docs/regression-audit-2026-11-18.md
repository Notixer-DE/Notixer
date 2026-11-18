# Regression audit — 2026-11-18

Baseline: `57a5a7627f5317f9953a52d5f01cbdbf9a19fcd4` (knowledge hub release).
The baseline release workflow completed successfully. This follow-up reviews the interaction of the new knowledge-management features with storage, navigation and editor state, alongside the existing application regression suite.

## Reproduced defects and corrections

| Area | Reproduction / effect | Correction |
| --- | --- | --- |
| Global tasks | An empty task query also returned PDF files as rows. | Apply the Markdown-only restriction before loading any document for task searches, including combinations with file-type filters. |
| Wiki completion | Move the caret from `[[O` in ordinary text to the same prefix inside a code block, or change a query and immediately press Enter: an old suggestion could still be accepted. | Invalidate options immediately when the query or its position changes. Validate the live selection and generation before insertion, including old pointer callbacks. |
| Automatic backup retention | Restart the scheduler without changing the library: another identical snapshot was created and could displace older recovery points. | Persist the library fingerprint with the successful snapshot reference; reuse it across restarts only while the referenced snapshot still exists. Flush pending edits before calculating it. |
| Backup recovery status | A temporary save failure replaced the success metadata; the error could remain after recovery or cause an unnecessary duplicate. | Preserve the last successful snapshot/fingerprint across errors, clear recovered errors without creating a duplicate, and replace status files atomically. |
| Backup ordering | Filename sorting relied on variable-precision ISO timestamp text. | Sort snapshots by filesystem modification time, with deterministic tie-breaking. |
| Restored saved views | A view referring to a folder with no restored notes lost its folder condition and matched all files. | Restore empty folders from catalog metadata and remap their identifiers. Preserve missing folders as unavailable filters rather than broadening the search. Compare remapped views before merging so repeated restores do not duplicate them or reuse conflicting names. |
| Restore validation | An invalid `automaticBackups` value could be discovered only after notebook copies had already been written. | Share complete preference validation between loading, saving and restore preflight, including template identifiers, types and size limits. Validate catalog metadata before writing copies. |
| Android share/capture handoff | When saving open notes failed, incoming shared text had already been cleared. | Consume pending text only when capture is actually opening; keep a retry action after failure and serialize overlapping handoffs. |

The six original focused reproductions failed on the baseline before their fixes. Additional regression cases cover shared-text retry, status recovery, empty-folder mapping and stale tap callbacks.

## Validation scope

- New storage and widget regressions exercise actual notebook files, backup archives, saved views, source controllers and library navigation.
- The complete Flutter suite covers the existing PDF/ink, lasso, single-page navigation, study, Markdown, sync, recovery and responsive-layout behaviors as well as these fixes.
- Static analysis and formatting are checked. CI additionally runs admin-dashboard tests, responsiveness probes, server integration and Android/Windows/Debian builds.
- This is not a claim that every physical-device input or operating-system condition has been tested. Hardware stylus behavior and device-specific Android share providers remain device-dependent.

No notebook format, existing note contents, application identity or signing key is changed by this audit.


## Responsive UI follow-up

- Removed the empty two-pixel workspace loading slot that exposed a black strip above desktop content. The loading indicator now exists only during loading.
- The graph canvas fills the available area. Search and graph options are revealed from the app bar; active local/tag filters remain removable. Node geometry accounts for accessibility text scaling.
- Search filters collapse by default on narrow screens. Controls and results share one scroll view, fixing overflow with the landscape phone keyboard.
- Journal day actions are compact; template selection uses a focused dialog. Backup help is available on demand, and redundant introductory text was removed from populated views.
- Markdown uses a compact 14px reading base while respecting system text scaling. Source and formatted views retain independent zoom levels, with toolbar controls and Ctrl/Cmd plus/minus/reset. Formatted Markdown supports touch pinch zoom without taking over ordinary one-finger scrolling. Zoom rebuilds visible blocks without reparsing the document.
- Added landscape keyboard, large-text graph, reading zoom, touch gesture, scrolling and parse-cache regressions. Actual Flutter widgets were rendered at desktop and phone portrait/landscape sizes, including 200% system text.

- Desktop library and Markdown navigation sidebars can be toggled independently of document tabs and toolbars. The existing PDF page overview toggle remains available.
