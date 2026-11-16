import 'dart:convert';
import 'dart:typed_data';

Uint8List largeScan({int pages = 500, int side = 4096}) {
  final data = BytesBuilder(copy: false)..add(ascii.encode('%PDF-1.7\n'));
  final offsets = <int>[0];
  void object(int id, List<int> bytes) {
    offsets.add(data.length);
    data.add(ascii.encode('$id 0 obj\n'));
    data.add(bytes);
    data.add(ascii.encode('\nendobj\n'));
  }

  object(1, ascii.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  object(
    2,
    ascii.encode(
      '<< /Type /Pages /Count $pages /Kids [${List.generate(pages, (i) => '${i + 5} 0 R').join(' ')}] >>',
    ),
  );
  final pixels = Uint8List(side * side * 3);
  var random = 123456789;
  for (var i = 0; i < pixels.length; i++) {
    random ^= (random << 13) & 0xffffffff;
    random ^= random >> 17;
    random ^= (random << 5) & 0xffffffff;
    pixels[i] = random & 255;
  }
  final image = BytesBuilder(copy: false)
    ..add(
      ascii.encode(
        '<< /Type /XObject /Subtype /Image /Width $side /Height $side /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length ${pixels.length} >>\nstream\n',
      ),
    )
    ..add(pixels)
    ..add(ascii.encode('\nendstream'));
  object(3, image.takeBytes());
  const content = 'q 595 0 0 842 0 0 cm /Scan Do Q';
  object(
    4,
    ascii.encode(
      '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    ),
  );
  for (var p = 0; p < pages; p++) {
    object(
      p + 5,
      ascii.encode(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Scan 3 0 R >> >> /Contents 4 0 R >>',
      ),
    );
  }
  final xref = data.length;
  data.add(
    ascii.encode(
      'xref\n0 ${offsets.length}\n0000000000 65535 f \n${offsets.skip(1).map((v) => '${v.toString().padLeft(10, '0')} 00000 n \n').join()}trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return data.takeBytes();
}
