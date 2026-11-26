import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/file_gateway.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/media.dart';
import '../data/media_gateway.dart';
import '../data/notebook.dart';
import 'document_tab.dart';
import 'organize_dialog.dart';
import 'workspace_chrome.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.name,
    required this.bytes,
    required this.format,
    this.note,
    this.repository,
    this.tabController,
    this.onLibrary,
  });
  final String name;
  final Uint8List bytes;
  final MediaFormat format;
  final Notebook? note;
  final LocalNotebookRepository? repository;
  final DocumentTabController? tabController;
  final Future<void> Function()? onLibrary;
  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  final _owner = LocalNotebookRepository.newId();
  bool _busy = false, _playing = false, _loaded = false;
  int _playRequest = 0;
  int _position = 0, _duration = 0;
  String? _error;
  Timer? _timer;
  late String _name = widget.name;
  late Notebook? _note = widget.note;
  @override
  void initState() {
    super.initState();
    if (widget.tabController case final tab?) {
      tab.attach(this, save: () async => true, pause: _pause);
      tab.commandFor = (action) => switch (action) {
        AppShortcut.export => _export,
        AppShortcut.mediaPlay when widget.format.kind != 'image' => _play,
        _ => null,
      };
      if (widget.repository case final repository?) {
        tab.refreshMetadata = () async {
          final notes = await repository.list();
          if (!mounted) return;
          for (final note in notes) {
            if (note.id == _note?.id) {
              _updateNote(note);
              return;
            }
          }
        };
      }
    }

    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!_loaded || !mounted || !Platform.isAndroid) return;
      try {
        final status = await MediaGateway.channel
            .invokeMapMethod<String, dynamic>('status');
        if (mounted && status != null && status['owner'] != _owner) {
          setState(() {
            _loaded = false;
            _playing = false;
            _position = 0;
            _duration = 0;
          });
          return;
        }
        if (mounted && status != null) {
          setState(() {
            _position = status['position'] as int;
            _duration = status['duration'] as int;
            _playing = status['playing'] as bool;
          });
        }
      } catch (_) {
        /* Playback can be stopped when Android backgrounds the app. */
      }
    });
  }

  void _pause() {
    _playRequest++;
    if (mounted && _playing) setState(() => _playing = false);
    if (Platform.isAndroid && widget.format.kind == 'audio') {
      unawaited(
        MediaGateway.channel
            .invokeMethod<void>('pause', {'owner': _owner})
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _action(() async {
    await FileGateway().save(
      FileGateway.exportName(_name, widget.format.extension),
      widget.bytes,
      widget.format.mime,
    );
  });

  void _updateNote(Notebook note) {
    setState(() {
      _note = note;
      _name = note.title;
    });
    widget.tabController?.update(note.title, false);
  }

  Future<void> _play() => _action(() async {
    final request = ++_playRequest;
    if (Platform.isAndroid && widget.format.kind == 'audio') {
      if (!_loaded) {
        final path = await MediaGateway.playbackFile(
          widget.bytes,
          widget.format,
        );
        if (!mounted || request != _playRequest) return;
        final duration = await MediaGateway.channel.invokeMethod<int>('play', {
          'path': path,
          'owner': _owner,
        });
        if (mounted) {
          setState(() {
            _loaded = true;
            _playing = request == _playRequest;
            _duration = duration ?? 0;
          });
        }
      } else {
        if (_playing) {
          await MediaGateway.channel.invokeMethod<void>('pause', {
            'owner': _owner,
          });
        } else {
          if (_position >= _duration) {
            await MediaGateway.channel.invokeMethod<void>('seek', {
              'position': 0,
              'owner': _owner,
            });
          }
          if (!mounted || request != _playRequest) return;
          await MediaGateway.channel.invokeMethod<void>('resume', {
            'owner': _owner,
          });
        }
        if (mounted && request == _playRequest) {
          setState(() => _playing = !_playing);
        }
      }
    } else {
      final path = await MediaGateway.playbackFile(widget.bytes, widget.format);
      if (!mounted || request != _playRequest) return;
      if (Platform.isAndroid) {
        await MediaGateway.channel.invokeMethod<void>('openVideo', {
          'path': path,
          'owner': _owner,
        });
      } else if (!await launchUrl(
        Uri.file(path),
        mode: LaunchMode.externalApplication,
      )) {
        throw const FormatException(
          'No media player is available. Export the file to open it in another app.',
        );
      }
    }
  });
  String _time(int millis) =>
      '${millis ~/ 60000}:${(millis ~/ 1000 % 60).toString().padLeft(2, '0')}';
  @override
  void dispose() {
    _timer?.cancel();
    if (Platform.isAndroid && widget.format.kind == 'audio') {
      unawaited(
        MediaGateway.channel
            .invokeMethod<void>('stop', {'owner': _owner})
            .catchError((Object _) {}),
      );
    }
    widget.tabController?.detach(this);
    super.dispose();
  }

  Future<void> _organize() => _action(() async {
    final updated = await showDialog<Notebook>(
      context: context,
      builder: (_) =>
          OrganizeDialog(note: _note!, repository: widget.repository!),
    );
    if (updated != null && mounted) {
      final saved = await widget.repository!.save(updated, widget.bytes);
      if (mounted) _updateNote(saved);
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leadingWidth: DocumentTabsChrome.leadingWidth(context),
      leading: DocumentNavigation(
        child: BackButton(
          onPressed: () {
            _pause();
            if (widget.onLibrary != null) {
              widget.onLibrary!();
            } else {
              Navigator.maybePop(context);
            }
          },
        ),
      ),
      title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (widget.tabController != null)
          PopupMenuButton<String>(
            tooltip: 'File menu',
            enabled: !_busy,
            onSelected: (action) =>
                action == 'organize' ? _organize() : _export(),
            itemBuilder: (_) => [
              if (widget.note != null && widget.repository != null)
                const PopupMenuItem(
                  value: 'organize',
                  child: Text('Folders and tags'),
                ),
              const PopupMenuItem(
                value: 'export',
                child: Text('Export media file'),
              ),
            ],
          )
        else ...[
          if (widget.note != null && widget.repository != null)
            IconButton(
              tooltip: 'Organize file',
              onPressed: _busy ? null : _organize,
              icon: const Icon(Icons.folder_outlined),
            ),
          IconButton(
            tooltip: 'Export media',
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          Expanded(
            child: widget.format.kind == 'image'
                ? InteractiveViewer(
                    minScale: .5,
                    maxScale: 8,
                    child: Center(
                      child: Image.memory(
                        widget.bytes,
                        cacheWidth: 2048,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const Text('This image cannot be displayed.'),
                      ),
                    ),
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 500),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.format.kind == 'audio'
                                  ? Icons.audio_file_outlined
                                  : Icons.video_file_outlined,
                              size: 64,
                            ),
                            const SizedBox(height: 16),
                            Text(_name, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            if (_loaded && _duration > 0) ...[
                              Slider(
                                value: _position.clamp(0, _duration).toDouble(),
                                max: _duration.toDouble(),
                                label: _time(_position),
                                onChanged: (value) => _action(
                                  () => MediaGateway.channel.invokeMethod<void>(
                                    'seek',
                                    {
                                      'position': value.round(),
                                      'owner': _owner,
                                    },
                                  ),
                                ),
                              ),
                              Text('${_time(_position)} / ${_time(_duration)}'),
                            ],
                            FilledButton.icon(
                              onPressed: _busy ? null : _play,
                              icon: Icon(
                                _playing ? Icons.pause : Icons.play_arrow,
                              ),
                              label: Text(
                                _playing
                                    ? 'Pause'
                                    : Platform.isAndroid
                                    ? 'Play'
                                    : 'Open in media player',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}
