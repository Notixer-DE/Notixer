import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:flutter/widgets.dart';

import 'web/browser_library.dart';
import 'web/web_app.dart';
import 'web/web_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledEditorAssets();
  final library = BrowserLibrary();
  runApp(
    NotixerWebApp(
      library: library,
      download: downloadBrowserFile,
      sync: WebSync(library),
    ),
  );
}
