# Notixer workspace

The workspace starts on **Today** and uses the same destination order on every screen. The selected file, search text, task filter and journal date stay in their original views while a document is open.

## Where actions moved

| Previous entry point | Current entry point |
| --- | --- |
| Library and its title search | **Files**, with a local title filter and list/grid control |
| New note, Import file, Add to-do and Quick capture | **Create → New file**, **Import file**, **Quick to-do** or **Capture to Inbox** |
| Knowledge Hub Search and Search PDFs | **Search** or **Ctrl+K**. Choose the PDF filter to search just PDF titles and embedded text. |
| Knowledge Hub Tasks and Unsorted to-dos | **Tasks** with **Today**, **Unsorted**, **Projects**, **All tasks** and **Completed** |
| Knowledge Hub Journal and journal template | **Journal**. Select a day, then open its note, add an entry or edit the template. |
| Knowledge Hub Inbox, Tags and library Trash | **Files → Inbox**, **Tags** and **Trash** |
| Knowledge Hub Views and Library Graph view | **Search → Saved views** or **Graph view**. Markdown notes also open their local graph. |
| Study today and Live Canvas | **More → Study** and **More → Live Canvas** on Android. **Today → Start studying** opens the first due review. |
| Markdown and notebook templates | **More → Templates**. Use the context tools in the editor to insert or save a template. |
| Backups and interrupted media capture | **More → Backups and recovery** |
| Sync, device pairing and shortcuts | **More → Settings**. The header cloud status also opens Sync and links to conflicts when present. |
| PDF toolbar and Tools and export | **Read**, **Draw**, **Pages** and **File menu** in the open PDF or notebook |
| Formatted and Markdown | **Read** and **Edit** in the open text note. Links open in **Read**. |

Holding a document tab open preserves its editor state. Use the back arrow to return to the originating section. On Android, the operating-system back gesture does the same. Press **Esc** to dismiss a menu or return from a secondary workspace destination. **Ctrl+F** opens the file picker. **More → Settings → Keyboard shortcuts** shows the installed bindings and lets you change them.

## Preview with example data

Launch the native preview on Linux with an independent temporary library. Resize the window to try the compact, tablet and desktop layouts. The example tasks, journal and notes are created by the same storage APIs as the installed app.

```sh
flutter run -d linux -t tools/design_preview.dart --dart-define=NOTIXER_DESIGN_INTERACTIVE=true
```

The headless preview tool captures the same Flutter views, including Today, Files, Journal and the PDF drawing mode. Run it from the repository after `flutter test`.

```sh
NOTER_DESIGN_DEVICES=phone-small,phone,tablet-600,tablet-768,tablet-landscape,desktop-small,desktop,phone-landscape,phone-large-text python3 tools/design_preview.py
```

Images are written under `build/design-preview/`.

## Acceptance checks

| Layout | Logical sizes |
| --- | --- |
| Phone | 320×568 and 390×844, then rotate and open the soft keyboard |
| Tablet | 600×960 and 768×1024 portrait, 1024×768 landscape |
| Desktop | 1280×720 and 1440×900, then resize to a narrow window |
| Accessibility | 200% text, screen reader, keyboard-only navigation and a landscape window with the keyboard visible |

- **Today and Tasks.** Add a quick to-do from Journal and check that it appears once in Unsorted. Add a due date, return to Today and start the focus timer directly. Leave the timer, open the task in Tasks, and inspect the same running time. Pause, resume, stop, correct and reset the tracked time. Choose **Countdown**, set a short duration and start it. Leave the focus view, then reopen it after the countdown expires and verify that work time continues to increase. Stop the timer and verify the saved total in the task row.
- **Study.** Use a notebook with two due covers. Start from Today, reveal the first answer and rate it. Inspect the next due time and continue with the second cover. Reopen the queue and verify the completed review. Repeat with a simulated save failure and retry the existing rating.
- **Journal and search.** Choose a past date, create an entry and use Search to find text in it. Back returns to the same query and result list. Rotate the device when Journal is open and verify the month, selected date and entry.
- **Reading and drawing.** Reopen recent PDF and Markdown files from Today. Inspect the restored position. Switch PDF modes, draw with the pen, select a few strokes with the lasso, and resize the window before undoing the change. On a stylus device, check pressure, side-button erasing and pinch zoom. Confirm that Read still selects text.
- **Files and recovery.** Select a PDF, a Markdown note and a media file. Move them together, export one file and move the selection to Trash. Restore a file and inspect its version history. Test permanent removal with disposable notes.
- **Sync and Live Canvas.** In a test vault, simulate a network error and continue editing offline. Inspect the error and retry from the workspace header after restoring connectivity. Verify that a settings conflict can be applied or archived. Start Live Canvas on Android and watch it in the Linux or Windows app. Check page changes, zoom, marker width and a lasso transform.
- **Keyboard and accessibility.** Use Tab, Shift+Tab, arrow keys, Enter and Esc. Check that selection, running timers and sync errors are announced by TalkBack, Orca or Narrator. Open the file picker with Ctrl+F and global search with Ctrl+K. With touch, repeat deletion through a visible task action and by swiping.

Record physical device findings by OS and version, logical size and input method. Keep rendering checks and simulated stylus tests separate from device measurements.
