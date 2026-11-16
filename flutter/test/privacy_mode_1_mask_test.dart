import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_hbb/models/privacy_mode_1_mask.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fixture;
  late File savedMask;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('rustdesk-privacy-mask-');
    savedMask = File(path.join(fixture.path, 'mask.bmp'));
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  test('selects an image and restores the default black mask', () async {
    expect(await savedMask.exists(), isFalse);

    final source = File(path.join(fixture.path, 'selected.png'));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 1);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await source.writeAsBytes(Uint8List.sublistView(png));
    image.dispose();
    picture.dispose();

    await savePrivacyMode1Mask(source, savedMask);
    final bytes = await savedMask.readAsBytes();
    expect(ByteData.sublistView(bytes).getInt32(22, Endian.little), -1);
    expect(bytes.sublist(54, 58), [0x56, 0x34, 0x12, 0]);
    await source.delete();
    expect(await savedMask.exists(), isTrue);

    await resetPrivacyMode1Mask(savedMask);
    expect(await savedMask.exists(), isFalse);
  });

  test(
    'an invalid image leaves the previously selected mask in place',
    () async {
      await savedMask.writeAsBytes([1, 2, 3]);
      final invalid = File(path.join(fixture.path, 'invalid.png'));
      await invalid.writeAsString('not image data');
      await expectLater(
        savePrivacyMode1Mask(invalid, savedMask),
        throwsA(anything),
      );
      expect(await savedMask.readAsBytes(), [1, 2, 3]);
    },
  );
}
