import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

const _maxSourceBytes = 20 * 1024 * 1024;
const _maxSourcePixels = 32 * 1024 * 1024;
const _maxMaskSide = 1920;

File privacyMode1MaskFile() {
  // FOLDERID_LocalAppData, also used by the window broker.
  final folder = GUIDFromString('{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}');
  final result = calloc<Pointer<Utf16>>();
  try {
    final status = SHGetKnownFolderPath(folder, 0, 0, result);
    if (FAILED(status)) {
      throw WindowsException(status);
    }
    return File(
      path.join(
        result.value.toDartString(),
        'RustDesk',
        'privacy-mode-1-mask.bmp',
      ),
    );
  } finally {
    CoTaskMemFree(result.value);
    calloc.free(result);
    calloc.free(folder);
  }
}

Future<void> savePrivacyMode1Mask(File source, File destination) async {
  if (await source.length() > _maxSourceBytes) {
    throw const FormatException('Privacy mask image file is too large');
  }
  final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > _maxSourcePixels) {
        throw const FormatException(
          'Privacy mask image dimensions are too large',
        );
      }
      final scale =
          math.max(descriptor.width, descriptor.height) / _maxMaskSide;
      final codec = await descriptor.instantiateCodec(
        targetWidth: scale > 1
            ? math.max(1, (descriptor.width / scale).round())
            : null,
        targetHeight: scale > 1
            ? math.max(1, (descriptor.height / scale).round())
            : null,
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final rgba = await image.toByteData();
          if (rgba == null) {
            throw const FormatException(
              'Could not decode the privacy mask image',
            );
          }
          final bitmap = _encodeMaskBitmap(image.width, image.height, rgba);
          final directory = await destination.parent.create(recursive: true);
          final scratch = await directory.createTemp('privacy-mask-');
          final staged = File(path.join(scratch.path, 'mask.bmp'));
          try {
            await staged.writeAsBytes(bitmap, flush: true);
            await staged.rename(destination.path);
          } finally {
            if (await staged.exists()) {
              await staged.delete();
            }
            await scratch.delete();
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Future<void> resetPrivacyMode1Mask(File destination) async {
  if (await destination.exists()) {
    await destination.delete();
  }
}

Uint8List _encodeMaskBitmap(int width, int height, ByteData rgba) {
  // Top-down, uncompressed 32-bit BMP, read by the broker's LoadImageW.
  const pixelOffset = 54;
  final pixelBytes = width * height * 4;
  final bytes = Uint8List(pixelOffset + pixelBytes);
  ByteData.sublistView(bytes)
    ..setUint16(0, 0x4d42, Endian.little)
    ..setUint32(2, bytes.length, Endian.little)
    ..setUint32(10, pixelOffset, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, -height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    ..setUint32(34, pixelBytes, Endian.little);
  for (var i = 0; i < pixelBytes; i += 4) {
    // Flutter's raw RGBA is premultiplied, so dropping alpha composites over black.
    bytes[pixelOffset + i] = rgba.getUint8(i + 2);
    bytes[pixelOffset + i + 1] = rgba.getUint8(i + 1);
    bytes[pixelOffset + i + 2] = rgba.getUint8(i);
  }
  return bytes;
}
