import 'package:flutter/widgets.dart';

import 'web/browser_library.dart';
import 'web/web_app.dart';

void main() {
  runApp(
    NotixerWebApp(library: BrowserLibrary(), download: downloadBrowserFile),
  );
}
