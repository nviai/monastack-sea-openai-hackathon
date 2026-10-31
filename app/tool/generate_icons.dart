// Renders the Monastack logo into every platform's launcher icon.
//
//   cd app && flutter test tool/generate_icons.dart
//
// Opaque icons (iOS, web maskable) are written as RGB PNGs without an alpha
// channel, as the App Store requires. The Windows .ico embeds PNG images.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/shared/brand/monastack_logo.dart';

Future<Uint8List> render(
  int size,
  LogoPlate plate, {
  bool opaque = false,
  double? glyphScale,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  paintMonastackLogo(
    canvas,
    ui.Size.square(size.toDouble()),
    plate: plate,
    glyphScale: glyphScale,
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return encodePng(size, size, data!.buffer.asUint8List(), opaque: opaque);
}

/// Minimal PNG encoder: 8-bit RGBA, or RGB when `opaque`.
Uint8List encodePng(
  int width,
  int height,
  Uint8List rgba, {
  bool opaque = false,
}) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final a = rgba[i + 3];
      if (opaque) {
        // Full-bleed plates cover every pixel, so alpha is 255 throughout.
        raw.add(rgba.sublist(i, i + 3));
      } else {
        // rawRgba is premultiplied; PNG stores straight alpha.
        raw.add([
          for (var c = 0; c < 3; c++)
            a == 0 ? 0 : (rgba[i + c] * 255 / a).round().clamp(0, 255),
          a,
        ]);
      }
    }
  }
  Uint8List chunk(String type, List<int> body) {
    final typed = [...type.codeUnits, ...body];
    return Uint8List.fromList([
      ..._u32(body.length),
      ...typed,
      ..._u32(_crc(typed)),
    ]);
  }

  final header = [..._u32(width), ..._u32(height), 8, opaque ? 2 : 6, 0, 0, 0];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...chunk('IHDR', header),
    ...chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes())),
    ...chunk('IEND', const []),
  ]);
}

List<int> _u32(int v) => [
  v >> 24 & 0xff,
  v >> 16 & 0xff,
  v >> 8 & 0xff,
  v & 0xff,
];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// ICO container with PNG-compressed entries.
Uint8List encodeIco(Map<int, Uint8List> images) {
  final out = BytesBuilder()
    ..add([0, 0, 1, 0, images.length & 0xff, images.length >> 8]);
  var offset = 6 + 16 * images.length;
  for (final MapEntry(key: size, value: png) in images.entries) {
    out.add([
      size >= 256 ? 0 : size,
      size >= 256 ? 0 : size,
      0,
      0,
      1,
      0,
      32,
      0,
      ..._le32(png.length),
      ..._le32(offset),
    ]);
    offset += png.length;
  }
  for (final png in images.values) {
    out.add(png);
  }
  return out.takeBytes();
}

List<int> _le32(int v) => [
  v & 0xff,
  v >> 8 & 0xff,
  v >> 16 & 0xff,
  v >> 24 & 0xff,
];

Future<void> write(String path, Future<Uint8List> bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(await bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate platform icons', () async {
    // In-app and documentation copy.
    await write(
      'assets/brand/monastack-logo.png',
      render(512, LogoPlate.rounded),
    );

    for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
      await write(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
        render(size, LogoPlate.rounded),
      );
    }

    const ios = {
      '20x20@1x': 20,
      '20x20@2x': 40,
      '20x20@3x': 60,
      '29x29@1x': 29,
      '29x29@2x': 58,
      '29x29@3x': 87,
      '40x40@1x': 40,
      '40x40@2x': 80,
      '40x40@3x': 120,
      '60x60@2x': 120,
      '60x60@3x': 180,
      '76x76@1x': 76,
      '76x76@2x': 152,
      '83.5x83.5@2x': 167,
      '1024x1024@1x': 1024,
    };
    for (final MapEntry(key: name, value: size) in ios.entries) {
      await write(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-$name.png',
        render(size, LogoPlate.fullBleed, opaque: true),
      );
    }

    const android = {
      'mdpi': 1.0,
      'hdpi': 1.5,
      'xhdpi': 2.0,
      'xxhdpi': 3.0,
      'xxxhdpi': 4.0,
    };
    for (final MapEntry(key: density, value: scale) in android.entries) {
      final dir = 'android/app/src/main/res/mipmap-$density';
      // Legacy launchers (API < 26) and the adaptive foreground (108 dp).
      await write(
        '$dir/ic_launcher.png',
        render((48 * scale).round(), LogoPlate.rounded),
      );
      await write(
        '$dir/ic_launcher_foreground.png',
        render((108 * scale).round(), LogoPlate.none, glyphScale: .62),
      );
    }

    await write('web/favicon.png', render(32, LogoPlate.rounded));
    for (final size in [192, 512]) {
      await write('web/icons/Icon-$size.png', render(size, LogoPlate.rounded));
      await write(
        'web/icons/Icon-maskable-$size.png',
        render(size, LogoPlate.fullBleed, opaque: true),
      );
    }

    await write(
      'windows/runner/resources/app_icon.ico',
      Future(
        () async => encodeIco({
          for (final size in [16, 24, 32, 48, 64, 128, 256])
            size: await render(size, LogoPlate.rounded),
        }),
      ),
    );
  });
}
