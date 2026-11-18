import 'dart:typed_data';

/// Portable formats stored as ordinary library documents, including in sync and
/// recovery archives. Playback availability depends on the device's codecs.
class MediaFormat {
  const MediaFormat(this.extension, this.kind, this.mime);
  final String extension, kind, mime;
  static const maxBytes = 128 * 1024 * 1024;
  static const formats = [
    MediaFormat('jpg', 'image', 'image/jpeg'),
    MediaFormat('jpeg', 'image', 'image/jpeg'),
    MediaFormat('png', 'image', 'image/png'),
    MediaFormat('webp', 'image', 'image/webp'),
    MediaFormat('gif', 'image', 'image/gif'),
    MediaFormat('mp4', 'video', 'video/mp4'),
    MediaFormat('mov', 'video', 'video/quicktime'),
    MediaFormat('webm', 'video', 'video/webm'),
    MediaFormat('m4a', 'audio', 'audio/mp4'),
    MediaFormat('mp3', 'audio', 'audio/mpeg'),
    MediaFormat('wav', 'audio', 'audio/wav'),
    MediaFormat('ogg', 'audio', 'audio/ogg'),
    MediaFormat('aac', 'audio', 'audio/aac'),
    MediaFormat('flac', 'audio', 'audio/flac'),
  ];
  static MediaFormat? of(String extension) {
    final normalized = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    for (final format in formats) {
      if (format.extension == normalized) return format;
    }
    return null;
  }

  void validate(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Media must be between 1 byte and 128 MB.');
    }
    bool at(int offset, List<int> signature) =>
        bytes.length >= offset + signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[offset + i] == signature[i],
        ).every((v) => v);
    bool text(int offset, String value) => at(offset, value.codeUnits);
    final valid = switch (extension) {
      'jpg' || 'jpeg' => at(0, [255, 216, 255]),
      'png' => at(0, [137, 80, 78, 71, 13, 10, 26, 10]),
      'gif' => text(0, 'GIF87a') || text(0, 'GIF89a'),
      'webp' => text(0, 'RIFF') && text(8, 'WEBP'),
      'mp4' || 'mov' || 'm4a' => text(4, 'ftyp'),
      'webm' => at(0, [26, 69, 223, 163]),
      'wav' => text(0, 'RIFF') && text(8, 'WAVE'),
      'ogg' => text(0, 'OggS'),
      'flac' => text(0, 'fLaC'),
      'mp3' =>
        text(0, 'ID3') ||
            (bytes.length > 1 && bytes[0] == 255 && bytes[1] & 224 == 224),
      'aac' => bytes.length > 1 && bytes[0] == 255 && bytes[1] & 246 == 240,
      _ => false,
    };
    if (!valid) {
      throw FormatException('The file is not valid $extension media.');
    }
  }
}
