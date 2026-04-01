import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/device_type.dart';
import 'image_converter.dart';
import 'omiglass_protocol.dart';

final Guid imageServiceUuid =
    Guid('12345678-1234-5678-1234-56789abcdef0');
final Guid imageDataCharUuid =
    Guid('12345678-1234-5678-1234-56789abcdef1');
final Guid imageCtrlCharUuid =
    Guid('12345678-1234-5678-1234-56789abcdef2');

const int cmdStart = 0x01;
const int cmdCommit = 0x02;
const int cmdCancel = 0x03;

const int statusReady = 0x00;
const int statusProgress = 0x01;
const int statusDisplaying = 0x10;
const int statusDone = 0x11;
const int statusError = 0xFF;

const _errorNames = {
  0x01: 'INVALID_SIZE',
  0x02: 'OVERFLOW',
  0x03: 'NOT_STARTED',
  0x04: 'INCOMPLETE',
};

enum TransferState {
  idle,
  connecting,
  connected,
  sending,
  displaying,
  done,
  error,
}

class BleImageTransfer {
  BluetoothDevice? _device;
  DeviceType _deviceType = DeviceType.unknown;
  
  // E-ink protocol (existing)
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _ctrlChar;
  StreamSubscription? _ctrlNotifySub;
  StreamSubscription? _connectionSub;
  
  // omiGlass protocol (new)
  OmiGlassProtocol? _omiProtocol;
  StreamSubscription? _omiImageSub;
  StreamSubscription? _omiLogSub;

  final _stateController = StreamController<TransferState>.broadcast();
  final _progressController = StreamController<double>.broadcast();
  final _logController = StreamController<String>.broadcast();

  Stream<TransferState> get stateStream => _stateController.stream;
  Stream<double> get progressStream => _progressController.stream;
  Stream<String> get logStream => _logController.stream;

  TransferState _state = TransferState.idle;
  TransferState get state => _state;

  BluetoothDevice? get connectedDevice => _device;
  DeviceType get deviceType => _deviceType;

  String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  void _setState(TransferState s) {
    _state = s;
    _log('[STATE] ${s.name}');
    _stateController.add(s);
  }

  void _log(String msg) {
    _logController.add('${_ts()} $msg');
  }

  Future<List<ScanResult>> scan(
      {Duration timeout = const Duration(seconds: 6)}) async {
    _log('[BLE] Scan started (timeout: ${timeout.inSeconds}s)');
    _log('[BLE] Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    final results = <ScanResult>[];

    try {
      var adapterState = FlutterBluePlus.adapterStateNow;
      _log('[BLE] Adapter state: $adapterState');
      if (adapterState != BluetoothAdapterState.on) {
        _log('[BLE] Waiting for adapter to turn on...');
        adapterState = await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 5), onTimeout: () {
          _log('[BLE] Adapter timeout - still: $adapterState');
          return adapterState;
        });
        _log('[BLE] Adapter state now: $adapterState');
        if (adapterState != BluetoothAdapterState.on) {
          _log('[BLE] ERROR: Bluetooth adapter is not ON');
          return results;
        }
      }

      // NOTE: Do NOT use withNames filter here.
      // On Android, OS-level name filters only check the primary advertising
      // packet. If the firmware puts the device name in the scan response
      // packet (sd[]), Android will never pass the result through, even though
      // nRF Connect (which scans without filter) can see it fine.
      // We scan for everything and filter manually below.
      _log('[BLE] Scanning (no filter) – will match name "the-tag" manually...');

      final scanSub = FlutterBluePlus.onScanResults.listen((scanResults) {
        for (final sr in scanResults) {
          final name = sr.advertisementData.advName.isNotEmpty
              ? sr.advertisementData.advName
              : sr.device.platformName;

          // Log every unique device seen (useful for debugging)
          final isNew = !results.any((e) => e.device.remoteId == sr.device.remoteId);
          final isTarget = name == 'the-tag';

          if (isNew) {
            final advUuids = sr.advertisementData.serviceUuids
                .map((u) => u.toString())
                .join(', ');
            _log('[BLE] Seen: "$name" (${sr.device.remoteId}) '
                'RSSI=${sr.rssi} dBm connectable=${sr.advertisementData.connectable}');
            _log('[BLE]   serviceUuids=[$advUuids]');

            if (isTarget) {
              results.add(sr);
              _log('[BLE] ✓ Matched target device: "$name"');
            }
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: timeout);

      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      await scanSub.cancel();
    } catch (e, st) {
      _log('[BLE] Scan error: $e');
      _log('[BLE] Stack: ${st.toString().split('\n').take(3).join(' | ')}');
    }

    _log('[BLE] Scan complete: ${results.length} device(s) found');
    return results;
  }

  Future<void> connect(BluetoothDevice device) async {
    _setState(TransferState.connecting);
    _log('[BLE] Connecting to "${device.platformName}" (${device.remoteId})...');

    try {
      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 10),
      );
      _log('[BLE] Connection established');

      _connectionSub = device.connectionState.listen((state) {
        _log('[BLE] Connection state changed: $state');
        if (state == BluetoothConnectionState.disconnected) {
          _cleanup();
          _setState(TransferState.idle);
        }
      });

      _log('[BLE] Discovering services...');
      final services = await device.discoverServices();
      _log('[BLE] Found ${services.length} service(s):');
      for (final s in services) {
        _log('[BLE]   svc ${s.serviceUuid} (${s.characteristics.length} chars)');
      }

      // Detect device type by service UUID
      _deviceType = DeviceType.unknown;
      for (final s in services) {
        if (s.serviceUuid == imageServiceUuid) {
          _deviceType = DeviceType.eink;
          _log('[BLE] Device type: E-ink Display');
          break;
        } else if (s.serviceUuid == omiServiceUuid) {
          _deviceType = DeviceType.camera;
          _log('[BLE] Device type: Camera Wearable (omiGlass)');
          break;
        }
      }

      if (_deviceType == DeviceType.unknown) {
        _log('[BLE] ERROR: Unknown device type (no matching service UUID)');
        throw Exception('Unknown device type');
      }

      _device = device;

      // Setup protocol based on device type
      if (_deviceType == DeviceType.eink) {
        await _setupEinkProtocol(services);
      } else if (_deviceType == DeviceType.camera) {
        await _setupOmiGlassProtocol();
      }

      _setState(TransferState.connected);
      _log('[BLE] Ready for image transfer');
    } catch (e, st) {
      _log('[BLE] Connection failed: $e');
      _log('[BLE] Stack: ${st.toString().split('\n').take(3).join(' | ')}');
      _setState(TransferState.error);
      rethrow;
    }
  }

  Future<void> _setupEinkProtocol(List<BluetoothService> services) async {
    _log('[BLE] Setting up E-ink protocol...');
    
    BluetoothService? imgService;
    for (final s in services) {
      if (s.serviceUuid == imageServiceUuid) {
        imgService = s;
        break;
      }
    }

    if (imgService == null) {
      _log('[BLE] ERROR: Image service $imageServiceUuid not found!');
      throw Exception('Image service not found on device');
    }
    
    _log('[BLE] Image service found');

    for (final c in imgService.characteristics) {
      final props = c.properties;
      _log('[BLE]   char ${c.characteristicUuid} '
          'props=[${_charPropsStr(props)}]');
      if (c.characteristicUuid == imageDataCharUuid) {
        _dataChar = c;
      } else if (c.characteristicUuid == imageCtrlCharUuid) {
        _ctrlChar = c;
      }
    }

    if (_dataChar == null) {
      _log('[BLE] ERROR: Data characteristic $imageDataCharUuid not found');
      throw Exception('Data characteristic not found');
    }
    if (_ctrlChar == null) {
      _log('[BLE] ERROR: Control characteristic $imageCtrlCharUuid not found');
      throw Exception('Control characteristic not found');
    }

    if (!Platform.isIOS) {
      _log('[BLE] Requesting MTU 247...');
      final newMtu = await _device!.requestMtu(247);
      _log('[BLE] MTU negotiated: $newMtu');
    } else {
      _log('[BLE] iOS: MTU auto-negotiated (${_device!.mtuNow})');
    }

    _log('[BLE] Enabling ctrl notifications...');
    await _ctrlChar!.setNotifyValue(true);
    _ctrlNotifySub = _ctrlChar!.onValueReceived.listen(_onCtrlNotify);
    _log('[BLE] Ctrl notifications enabled');
    _log('[BLE] E-ink protocol ready (MTU=${_device!.mtuNow})');
  }

  Future<void> _setupOmiGlassProtocol() async {
    _log('[BLE] Setting up omiGlass protocol...');
    
    _omiProtocol = OmiGlassProtocol();
    final success = await _omiProtocol!.setup(_device!);
    
    if (!success) {
      _log('[BLE] ERROR: Failed to setup omiGlass protocol');
      throw Exception('Failed to setup omiGlass protocol');
    }

    // Forward omiGlass logs to our log stream
    _omiLogSub = _omiProtocol!.logStream.listen((msg) {
      _logController.add(msg);
    });

    // Forward received images to UI (can be handled by UI layer)
    _omiImageSub = _omiProtocol!.imageStream.listen((imageData) {
      _log('[OMI] Image received: ${imageData.length} bytes');
      // UI can subscribe to _omiProtocol.imageStream directly
    });

    _log('[BLE] omiGlass protocol ready');
  }

  String _charPropsStr(CharacteristicProperties p) {
    final parts = <String>[];
    if (p.read) parts.add('R');
    if (p.write) parts.add('W');
    if (p.writeWithoutResponse) parts.add('WnR');
    if (p.notify) parts.add('N');
    if (p.indicate) parts.add('I');
    return parts.join(',');
  }

  void _onCtrlNotify(List<int> value) {
    final hex = value.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
    _log('[NOTIFY] raw=[$hex] (${value.length} bytes)');

    if (value.isEmpty) return;

    switch (value[0]) {
      case statusReady:
        _log('[NOTIFY] READY: firmware ready for data');
        break;
      case statusProgress:
        if (value.length >= 3) {
          final received = value[1] | (value[2] << 8);
          final pct = (received / bufferSize * 100).toStringAsFixed(1);
          _progressController.add(received / bufferSize);
          _log('[NOTIFY] PROGRESS: $received/$bufferSize bytes ($pct%)');
        } else {
          _log('[NOTIFY] PROGRESS: malformed (need 3 bytes, got ${value.length})');
        }
        break;
      case statusDisplaying:
        _log('[NOTIFY] DISPLAYING: e-ink refresh started');
        _setState(TransferState.displaying);
        break;
      case statusDone:
        _log('[NOTIFY] DONE: display refresh complete');
        _setState(TransferState.done);
        break;
      case statusError:
        final errCode = value.length > 1 ? value[1] : 0;
        final errName = _errorNames[errCode] ?? 'UNKNOWN';
        _log('[NOTIFY] ERROR: code=0x${errCode.toRadixString(16)} ($errName)');
        _setState(TransferState.error);
        break;
      default:
        _log('[NOTIFY] UNKNOWN status: 0x${value[0].toRadixString(16)}');
    }
  }

  Future<void> sendImage(Uint8List imageBuffer) async {
    if (_device == null) {
      _log('[SEND] ERROR: not connected');
      throw Exception('Not connected');
    }

    // Route to appropriate protocol
    if (_deviceType == DeviceType.eink) {
      await _sendImageEink(imageBuffer);
    } else if (_deviceType == DeviceType.camera) {
      _log('[SEND] Camera devices receive images automatically - no send needed');
      throw Exception('Camera devices do not support sending images');
    } else {
      throw Exception('Unknown device type');
    }
  }

  Future<void> _sendImageEink(Uint8List imageBuffer) async {
    if (_dataChar == null || _ctrlChar == null) {
      _log('[SEND] ERROR: not connected (dataChar=${_dataChar != null}, ctrlChar=${_ctrlChar != null})');
      throw Exception('Not connected');
    }

    _setState(TransferState.sending);
    _progressController.add(0.0);

    final size = imageBuffer.length;
    _log('[SEND] Image buffer: $size bytes (expected $bufferSize)');
    _log('[SEND] First 8 bytes: ${imageBuffer.take(8).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');

    _log('[SEND] Writing START cmd [0x01, 0x${(size & 0xFF).toRadixString(16)}, 0x${((size >> 8) & 0xFF).toRadixString(16)}]');
    final sw = Stopwatch()..start();
    await _ctrlChar!.write([cmdStart, size & 0xFF, (size >> 8) & 0xFF]);
    _log('[SEND] START cmd written (${sw.elapsedMilliseconds}ms)');

    await Future.delayed(const Duration(milliseconds: 100));

    final mtu = _device!.mtuNow;
    final chunkSize = mtu - 3;
    final totalChunks = (size / chunkSize).ceil();
    _log('[SEND] MTU=$mtu, chunkSize=$chunkSize, totalChunks=$totalChunks');

    sw.reset();
    int offset = 0;
    int chunkNum = 0;
    while (offset < size) {
      final end = (offset + chunkSize).clamp(0, size);
      final chunk = imageBuffer.sublist(offset, end);
      chunkNum++;

      try {
        await _dataChar!.write(chunk, withoutResponse: true);
      } catch (e) {
        _log('[SEND] ERROR writing chunk $chunkNum at offset $offset: $e');
        _setState(TransferState.error);
        rethrow;
      }
      offset = end;

      _progressController.add(offset / size);

      if (offset % 2048 < chunkSize) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
    final elapsed = sw.elapsedMilliseconds;
    final kbps = elapsed > 0 ? (size * 8 / elapsed).toStringAsFixed(1) : '?';
    _log('[SEND] All $chunkNum chunks sent ($size bytes in ${elapsed}ms, ~$kbps kbit/s)');

    _log('[SEND] Writing COMMIT cmd [0x02]');
    await _ctrlChar!.write([cmdCommit]);
    _log('[SEND] COMMIT written, waiting for firmware...');
  }

  // Access to omiGlass image stream for UI
  Stream<Uint8List>? get omiImageStream => _omiProtocol?.imageStream;

  Future<void> disconnect() async {
    if (_device != null) {
      _log('[BLE] Disconnecting from ${_device!.remoteId}...');
      await _device!.disconnect();
      _log('[BLE] Disconnect request sent');
    }
    _cleanup();
    _setState(TransferState.idle);
  }

  void _cleanup() {
    // E-ink protocol cleanup
    _ctrlNotifySub?.cancel();
    _ctrlNotifySub = null;
    _dataChar = null;
    _ctrlChar = null;
    
    // omiGlass protocol cleanup
    _omiImageSub?.cancel();
    _omiImageSub = null;
    _omiLogSub?.cancel();
    _omiLogSub = null;
    _omiProtocol?.cleanup();
    _omiProtocol = null;
    
    // Common cleanup
    _connectionSub?.cancel();
    _connectionSub = null;
    _device = null;
    _deviceType = DeviceType.unknown;
  }

  void dispose() {
    _cleanup();
    _omiProtocol?.dispose();
    _stateController.close();
    _progressController.close();
    _logController.close();
  }
}
