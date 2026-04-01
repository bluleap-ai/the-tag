import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;

// omiGlass protocol UUIDs
final Guid omiServiceUuid = Guid('19b10000-e8f2-537e-4f6c-d104768a1214');
final Guid omiPhotoDataUuid = Guid('19b10005-e8f2-537e-4f6c-d104768a1214');

class OmiGlassProtocol {
  BluetoothCharacteristic? _photoChar;
  StreamSubscription? _photoNotifySub;

  final _imageController = StreamController<Uint8List>.broadcast();
  final _logController = StreamController<String>.broadcast();

  Stream<Uint8List> get imageStream => _imageController.stream;
  Stream<String> get logStream => _logController.stream;

  List<int> _buffer = [];
  int _expectedChunks = 0;
  int _receivedChunks = 0;

  void _log(String msg) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    _logController.add('$ts [OMI] $msg');
  }

  Future<bool> setup(BluetoothDevice device) async {
    try {
      _log('Discovering services...');
      final services = await device.discoverServices();

      BluetoothService? omiService;
      for (final s in services) {
        if (s.serviceUuid == omiServiceUuid) {
          omiService = s;
          break;
        }
      }

      if (omiService == null) {
        _log('ERROR: omiGlass service not found');
        return false;
      }

      _log('omiGlass service found');

      for (final c in omiService.characteristics) {
        if (c.characteristicUuid == omiPhotoDataUuid) {
          _photoChar = c;
          break;
        }
      }

      if (_photoChar == null) {
        _log('ERROR: Photo data characteristic not found');
        return false;
      }

      _log('Enabling photo notifications...');
      await _photoChar!.setNotifyValue(true);
      _photoNotifySub = _photoChar!.onValueReceived.listen(_onPhotoData);
      _log('Photo notifications enabled - ready to receive images');

      return true;
    } catch (e) {
      _log('Setup error: $e');
      return false;
    }
  }

  void _onPhotoData(List<int> value) {
    if (value.length >= 2 && value[0] == 0xFF && value[1] == 0xFF) {
      // End marker
      _log('End marker received - image complete ($_receivedChunks chunks, ${_buffer.length} bytes)');
      if (_buffer.isNotEmpty) {
        // Debug: Log first 32 bytes to analyze format
        final preview = _buffer.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        _log('First 32 bytes: $preview');
        
        // Check if data is JPEG (starts with FF D8) or raw RGB565
        if (_buffer.length >= 2 && _buffer[0] == 0xFF && _buffer[1] == 0xD8) {
          // JPEG format - send as-is
          _log('Detected JPEG format');
          _imageController.add(Uint8List.fromList(_buffer));
        } else {
          // Raw RGB565 format - convert to PNG for display
          _log('Detected RGB565 format, converting to PNG...');
          final pngData = _convertRgb565ToPng(_buffer);
          if (pngData != null) {
            _log('RGB565 conversion successful');
            _imageController.add(pngData);
          } else {
            _log('ERROR: Failed to convert RGB565 to PNG');
          }
        }
      }
      _buffer.clear();
      _receivedChunks = 0;
      return;
    }

    if (value.length < 2) {
      _log('Invalid chunk: too short (${value.length} bytes)');
      return;
    }

    final idx = value[0] | (value[1] << 8);
    final dataStart = idx == 0 ? 3 : 2; // First chunk has orientation byte

    if (value.length <= dataStart) {
      _log('Invalid chunk $idx: no data after header');
      return;
    }

    final data = value.sublist(dataStart);
    _buffer.addAll(data);
    _receivedChunks++;

    if (_receivedChunks % 50 == 0) {
      _log('Received $_receivedChunks chunks (${_buffer.length} bytes)');
    }
  }

  Uint8List? _convertRgb565ToPng(List<int> rgb565Data) {
    try {
      // Detect image dimensions from data size
      // Common sizes: 160x120=38400, 320x240=153600, 640x480=614400
      int width, height;
      final pixelCount = rgb565Data.length ~/ 2;
      
      if (pixelCount == 160 * 120) {
        width = 160;
        height = 120;
      } else if (pixelCount == 320 * 240) {
        width = 320;
        height = 240;
      } else if (pixelCount == 640 * 480) {
        width = 640;
        height = 480;
      } else {
        _log('Unknown image size: ${rgb565Data.length} bytes ($pixelCount pixels)');
        return null;
      }

      _log('Detected image size: ${width}x$height');

      // Decode as RGB565 big-endian (OV2640 RGB565 output)
      final rgb888 = Uint8List(width * height * 3);
      
      for (int i = 0; i < pixelCount; i++) {
        // RGB565 big-endian: high byte first
        final px = (rgb565Data[i * 2] << 8) | rgb565Data[i * 2 + 1];
        
        final r = (px >> 11) & 0x1F;
        final g = (px >> 5) & 0x3F;
        final b = px & 0x1F;
        
        rgb888[i * 3 + 0] = (r << 3) | (r >> 2);
        rgb888[i * 3 + 1] = (g << 2) | (g >> 4);
        rgb888[i * 3 + 2] = (b << 3) | (b >> 2);
      }

      // Encode as PNG using image package
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgb888.buffer,
        numChannels: 3,
      );
      
      final pngBytes = img.encodePng(image);
      _log('PNG encoded: ${pngBytes.length} bytes');
      return Uint8List.fromList(pngBytes);
    } catch (e) {
      _log('Image conversion error: $e');
      return null;
    }
  }

  void cleanup() {
    _photoNotifySub?.cancel();
    _photoNotifySub = null;
    _photoChar = null;
    _buffer.clear();
  }

  void dispose() {
    cleanup();
    _imageController.close();
    _logController.close();
  }
}
