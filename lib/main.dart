import 'dart:io';
import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data/notebook.dart';
import 'data/library_backup.dart';
import 'data/file_gateway.dart';
import 'ui/document_workspace.dart';
import 'input/stylus_eraser.dart';
import 'ui/noter_theme.dart';

void main() {
  NoterBinding();
  registerBundledEditorAssets();
  FileGateway.initialize();
  runApp(const NoterApp());
}

class NoterApp extends StatelessWidget {
  const NoterApp({super.key, this.repository});
  final LocalNotebookRepository? repository;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Notixer',
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    supportedLocales: const [Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      DartPdfEditorLocalizations.delegate,
    ],
    theme: NoterTheme.light,
    builder: (context, child) => Theme(
      data: NoterTheme.forWindow(context),
      child: child ?? const SizedBox.shrink(),
    ),
    home: _Startup(repository: repository),
  );
}

class _Startup extends StatefulWidget {
  const _Startup({this.repository});
  final LocalNotebookRepository? repository;
  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> with WidgetsBindingObserver {
  late final Future<LocalNotebookRepository> _repository;
  LocalNotebookRepository? _opened;
  AutomaticBackupScheduler? _backups;
  Future<bool> Function()? _previousFallback;
  late final Future<bool> Function() _fallbackHandler = _flushBeforeClose;
  Future<bool> _flushBeforeClose() async {
    await _opened?.flush();
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _previousFallback = FileGateway.fallbackBeforeClose;
    _repository = _open();
  }

  Future<LocalNotebookRepository> _open() async {
    final repository =
        widget.repository ??
        LocalNotebookRepository(
          Directory(
            p.join((await getApplicationSupportDirectory()).path, 'notebooks'),
          ),
        );
    if (mounted) {
      _opened = repository;
      _backups = AutomaticBackupScheduler(
        repository,
        prepare: FileGateway.prepareClose,
      )..start();
      FileGateway.fallbackBeforeClose = _fallbackHandler;
    }
    return repository;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _backups?.check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backups?.dispose();
    if (identical(FileGateway.fallbackBeforeClose, _fallbackHandler)) {
      FileGateway.fallbackBeforeClose = _previousFallback;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _repository,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: SelectableText('Could not open storage: ${snapshot.error}'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return DocumentWorkspace(repository: snapshot.data!);
    },
  );
}
