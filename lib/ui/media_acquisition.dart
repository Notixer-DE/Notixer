import 'dart:async';
import 'package:flutter/material.dart';
import '../data/media.dart';
import '../data/media_gateway.dart';

Future<ImportedMedia?> acquireMedia(
  BuildContext context, {
  bool imagesOnly = false,
  int limit = MediaFormat.maxBytes,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(imagesOnly ? 'Choose image' : 'Choose media file'),
            onTap: () => Navigator.pop(context, 'file'),
          ),
          if (MediaGateway.canCapture) ...[
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            if (!imagesOnly) ...[
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Record video'),
                onTap: () => Navigator.pop(context, 'video'),
              ),
              ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('Record voice message'),
                onTap: () => Navigator.pop(context, 'voice'),
              ),
            ],
          ],
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'file') {
    return MediaGateway.pick(imagesOnly: imagesOnly, limit: limit);
  }
  if (choice != 'voice') {
    return MediaGateway.capture(video: choice == 'video', limit: limit);
  }
  return showDialog<ImportedMedia>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _VoiceRecorder(limit: limit),
  );
}

class _VoiceRecorder extends StatefulWidget {
  const _VoiceRecorder({required this.limit});
  final int limit;
  @override
  State<_VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<_VoiceRecorder>
    with WidgetsBindingObserver {
  bool _recording = false, _busy = false, _stopped = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _recording) {
      _timer?.cancel();
      setState(() => _stopped = true);
    }
  }

  String? _error;
  Timer? _timer;
  int _seconds = 0;
  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MediaGateway.channel.invokeMethod<void>('startRecording');
      if (!mounted) return;
      setState(() {
        _recording = true;
        _stopped = false;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted) return;
        setState(() => _seconds++);
        if (_seconds >= 600) await _finish();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    if (_busy || !_recording) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      final path = await MediaGateway.channel.invokeMethod<String>(
        'stopRecording',
      );
      if (path == null) throw const FormatException('No audio was recorded.');
      final media = await MediaGateway.consumeCapture(
        path,
        limit: widget.limit,
      );
      if (mounted) {
        Navigator.pop(
          context,
          ImportedMedia(
            'Voice ${DateTime.now().toIso8601String().replaceAll(':', '-')}.m4a',
            media.bytes,
            media.format,
            temporaryPath: media.temporaryPath,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _recording = false;
          _error = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      MediaGateway.channel
          .invokeMethod<void>('cancelRecording')
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Voice message'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _recording ? Icons.mic : Icons.mic_none,
            size: 36,
            color: _recording ? Theme.of(context).colorScheme.error : null,
          ),
          const SizedBox(height: 12),
          Text(
            _stopped
                ? 'Recording stopped. Add it or cancel.'
                : _recording
                ? '${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}'
                : 'Ready to record',
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : _recording
              ? _finish
              : _start,
          icon: Icon(_recording ? Icons.stop : Icons.mic),
          label: Text(_recording ? 'Stop and add' : 'Start recording'),
        ),
      ],
    ),
  );
}
