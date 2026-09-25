import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

String decodeQrImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Не удалось прочитать изображение');
  }
  final rgba = decoded
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.rgba);
  final source = RGBLuminanceSource(
    decoded.width,
    decoded.height,
    rgba.buffer.asInt32List(rgba.offsetInBytes, rgba.lengthInBytes ~/ 4),
  );
  try {
    return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source))).text;
  } catch (_) {
    throw const FormatException('QR-код на изображении не найден');
  }
}
