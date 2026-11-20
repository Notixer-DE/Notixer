import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:flutter/widgets.dart';

import 'web/browser_library.dart';
import 'web/live_viewer_page.dart';
import 'web/web_app.dart';
import 'web/web_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledEditorAssets();
  final url = Uri.base;
  if (url.fragment.startsWith('live?')) {
    runApp(LiveViewerApp(url: url));
    return;
  }
  final library = BrowserLibrary();
  runApp(
    NotixerWebApp(
      library: library,
      download: downloadBrowserFile,
      sync: WebSync(library),
    ),
  );
}
