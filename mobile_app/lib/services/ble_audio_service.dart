import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'lc3_decoder.dart';

// ---------------------------------------------------------------------------
// BLE UUID constants – must match firmware
// ---------------------------------------------------------------------------

// E-ink firmware audio UUIDs
final Guid audioServiceUuid =
    Guid('12345678-1234-5678-1234-56789abcdef3');
final Guid audioDataCharUuid =
    Guid('12345678-1234-5678-1234-56789abcdef4');
final Guid audioCtrlCharUuid =
    Guid('12345678-1234-5678-1234-56789abcdef5');

// omiGlass/veea firmware audio UUIDs (under OMI service)
final Guid omiAudioServiceUuid =
    Guid('19b10000-e8f2-537e-4f6c-d104768a1214');
final Guid omiAudioDataCharUuid =
    Guid('19b10001-e8f2-537e-4f6c-d104768a1214');
final Guid omiAudioCtrlCharUuid =
    Guid('19b10002-e8f2-537e-4f6c-d104768a1214');

// Control commands (phone → firmware)
const int audioCmdStart = 0x01;
const int audioCmdStop  = 0x02;

// Status notifications (firmware → phone, on ctrl char)
const int audioStatusRecording = 0x01;
const int audioStatusStopped   = 0x02;
const int audioStatusError     = 0xFF;

// Audio parameters that must match the firmware
const int audioSampleRate    = 16000;  // Hz
const int audioBitsPerSample = 16;
const int audioChannels      = 1;      // mono
const int audioFrameBytes    = 40;     // LC3 frame size at 32 kbps / 10 ms
const int audioFrameHeaderSize = 4;    // [seq_lo, seq_hi, len_lo, len_hi]

// ---------------------------------------------------------------------------
// State enum
// ---------------------------------------------------------------------------

enum AudioStreamState {
  idle,
  connecting,
  ready,
  recording,
  stopped,
  error,
}

// ---------------------------------------------------------------------------
// BleAudioService
// ---------------------------------------------------------------------------

class BleAudioService {
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _ctrlChar;
  StreamSubscription? _dataNotifySub;
  StreamSubscription? _ctrlNotifySub;

  final _stateController =
      StreamController<AudioStreamState>.broadcast();
  final _framesController =
      StreamController<Uint8List>.broadcast();
  final _logController = StreamController<String>.broadcast();

  Stream<AudioStreamState> get stateStream => _stateController.stream;

  /// Each emitted value is the raw LC3 payload of one audio frame.
  Stream<Uint8List> get framesStream => _framesController.stream;

  Stream<String> get logStream => _logController.stream;

  AudioStreamState _state = AudioStreamState.idle;
  AudioStreamState get state => _state;

  /// All received LC3 frame payloads accumulated during the current session.
  final List<Uint8List> _recordedFrames = [];
  List<Uint8List> get recordedFrames => List.unmodifiable(_recordedFrames);

  int get recordedFrameCount => _recordedFrames.length;

  /// Approximate duration of recorded audio in seconds.
  double get recordedDurationSeconds =>
      _recordedFrames.length * 10.0 / 1000.0; // 10 ms per frame

  String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  void _setState(AudioStreamState s) {
    _state = s;
    _log('[STATE] ${s.name}');
    _stateController.add(s);
  }

  void _log(String msg) {
    final logLine = '${_ts()} $msg';
    print(logLine);
    _logController.add(logLine);
  }

  // -------------------------------------------------------------------------
  // Attach to a connected device that already has services discovered
  // -------------------------------------------------------------------------

  Future<void> attach(BluetoothDevice device) async {
    _setState(AudioStreamState.connecting);
    _log('[AUDIO] Looking for audio service on ${device.platformName}...');

    final services = await device.discoverServices();

    BluetoothService? audioSvc;
    Guid? matchedDataUuid;
    Guid? matchedCtrlUuid;

    // Try e-ink audio service UUID first
    for (final s in services) {
      if (s.serviceUuid == audioServiceUuid) {
        audioSvc = s;
        matchedDataUuid = audioDataCharUuid;
        matchedCtrlUuid = audioCtrlCharUuid;
        _log('[AUDIO] Found e-ink audio service');
        break;
      }
    }

    // Try omiGlass/veea audio service UUID
    if (audioSvc == null) {
      for (final s in services) {
        if (s.serviceUuid == omiAudioServiceUuid) {
          audioSvc = s;
          matchedDataUuid = omiAudioDataCharUuid;
          matchedCtrlUuid = omiAudioCtrlCharUuid;
          _log('[AUDIO] Found omiGlass audio service');
          break;
        }
      }
    }

    if (audioSvc == null) {
      _log('[AUDIO] ERROR: No audio service found (tried e-ink and omiGlass UUIDs)');
      _setState(AudioStreamState.error);
      throw Exception('Audio service not found on device');
    }

    for (final c in audioSvc.characteristics) {
      if (c.characteristicUuid == matchedDataUuid) {
        _dataChar = c;
      } else if (c.characteristicUuid == matchedCtrlUuid) {
        _ctrlChar = c;
      }
    }

    if (_dataChar == null || _ctrlChar == null) {
      _log('[AUDIO] ERROR: Missing characteristic(s)');
      _setState(AudioStreamState.error);
      throw Exception('Audio characteristic(s) not found');
    }

    // Subscribe to control notifications (status from firmware)
    await _ctrlChar!.setNotifyValue(true);
    _ctrlNotifySub = _ctrlChar!.onValueReceived.listen(_onCtrlNotify);
    _log('[AUDIO] Ctrl notifications enabled');

    _setState(AudioStreamState.ready);
    _log('[AUDIO] Audio service ready');
  }

  // -------------------------------------------------------------------------
  // Start / stop recording session
  // -------------------------------------------------------------------------

  Future<void> startRecording() async {
    if (_dataChar == null || _ctrlChar == null) {
      _log('[AUDIO] ERROR: not attached to device');
      throw Exception('Not attached to audio service');
    }

    _recordedFrames.clear();

    // Subscribe to audio data notifications
    await _dataChar!.setNotifyValue(true);
    _dataNotifySub = _dataChar!.onValueReceived.listen(_onDataNotify);
    _log('[AUDIO] Data notifications enabled');

    // Tell firmware to start recording
    await _ctrlChar!.write([audioCmdStart]);
    _log('[AUDIO] CMD_START sent');

    _setState(AudioStreamState.recording);
  }

  Future<void> stopRecording() async {
    if (_ctrlChar == null) return;

    // Tell firmware to stop
    await _ctrlChar!.write([audioCmdStop]);
    _log('[AUDIO] CMD_STOP sent');

    // Unsubscribe from data notifications
    await _dataChar?.setNotifyValue(false);
    _dataNotifySub?.cancel();
    _dataNotifySub = null;

    _setState(AudioStreamState.stopped);
    _log('[AUDIO] Recording stopped – ${_recordedFrames.length} frames '
        '(~${recordedDurationSeconds.toStringAsFixed(1)} s)');
  }

  // -------------------------------------------------------------------------
  // Build a WAV file from the buffered audio frames for playback.
  // Uses native liblc3 decoder via FFI to convert LC3 → PCM S16.
  // -------------------------------------------------------------------------

  Lc3Decoder? _lc3Decoder;

  Uint8List buildWavFromRecording() {
    _lc3Decoder ??= Lc3Decoder(
      dtUs: 10000,  // 10 ms frames
      srHz: audioSampleRate,
    );
    _lc3Decoder!.init();

    try {
      final pcmData = _lc3Decoder!.decodeFrames(_recordedFrames);
      final peak = _pcmPeakAbs(pcmData);
      final rms = _pcmRms(pcmData);

      _log('[DECODE] PCM stats: peak=$peak rms=${rms.toStringAsFixed(1)}');

      final normalizedPcm = _normalizePcmIfNeeded(pcmData, peak);

      _log('[DECODE] Decoded ${_recordedFrames.length} LC3 frames '
          '→ ${normalizedPcm.length} bytes PCM');
      return _wrapInWav(normalizedPcm);
    } finally {
      _lc3Decoder!.dispose();
    }
  }

  static int _pcmPeakAbs(Uint8List pcmBytes) {
    final byteData = ByteData.sublistView(pcmBytes);
    int peak = 0;

    for (int i = 0; i + 1 < pcmBytes.length; i += 2) {
      final sample = byteData.getInt16(i, Endian.little).abs();
      if (sample > peak) {
        peak = sample;
      }
    }

    return peak;
  }

  static double _pcmRms(Uint8List pcmBytes) {
    final byteData = ByteData.sublistView(pcmBytes);
    if (pcmBytes.length < 2) {
      return 0;
    }

    double sumSquares = 0;
    int count = 0;

    for (int i = 0; i + 1 < pcmBytes.length; i += 2) {
      final sample = byteData.getInt16(i, Endian.little).toDouble();
      sumSquares += sample * sample;
      count++;
    }

    if (count == 0) {
      return 0;
    }

    return math.sqrt(sumSquares / count);
  }

  Uint8List _normalizePcmIfNeeded(Uint8List pcmBytes, int peak) {
    if (peak == 0) {
      _log('[DECODE] PCM is all-zero after decode');
      return pcmBytes;
    }

    const targetPeak = 12000;
    const minUsefulPeak = 800;
    if (peak >= minUsefulPeak) {
      return pcmBytes;
    }

    final gain = (targetPeak / peak).clamp(1.0, 24.0);
    _log('[DECODE] Applying gain x${gain.toStringAsFixed(2)} (peak=$peak)');

    final input = ByteData.sublistView(pcmBytes);
    final out = ByteData(pcmBytes.length);

    for (int i = 0; i + 1 < pcmBytes.length; i += 2) {
      final s = input.getInt16(i, Endian.little);
      int v = (s * gain).round();
      if (v > 32767) {
        v = 32767;
      } else if (v < -32768) {
        v = -32768;
      }
      out.setInt16(i, v, Endian.little);
    }

    return out.buffer.asUint8List();
  }

  static Uint8List _wrapInWav(Uint8List pcmBytes) {
    const sampleRate    = audioSampleRate;
    const numChannels   = audioChannels;
    const bitsPerSample = audioBitsPerSample;
    final byteRate      = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign    = numChannels * bitsPerSample ~/ 8;
    final dataLen       = pcmBytes.length;

    final header = ByteData(44);
    // RIFF chunk
    header.setUint8(0, 0x52); header.setUint8(1, 0x49);
    header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataLen, Endian.little);
    header.setUint8(8, 0x57); header.setUint8(9, 0x41);
    header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt  sub-chunk
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);   // PCM
    header.setUint16(20, 1, Endian.little);    // AudioFormat = PCM
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data sub-chunk
    header.setUint8(36, 0x64); header.setUint8(37, 0x61);
    header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataLen, Endian.little);

    final result = BytesBuilder();
    result.add(header.buffer.asUint8List());
    result.add(pcmBytes);
    return result.toBytes();
  }

  // -------------------------------------------------------------------------
  // Notification handlers
  // -------------------------------------------------------------------------

  void _onDataNotify(List<int> value) {
    if (value.length < audioFrameHeaderSize) {
      _log('[AUDIO] Short data notification (${value.length} bytes), ignoring');
      return;
    }

    final seq = value[0] | (value[1] << 8);
    final len = value[2] | (value[3] << 8);
    final payloadLen = value.length - audioFrameHeaderSize;
    if (len <= 0 || payloadLen < len) {
      _log('[AUDIO] Invalid frame seq=$seq hdr_len=$len payload_len=$payloadLen, ignoring');
      return;
    }

    final payload = Uint8List.fromList(
      value.sublist(audioFrameHeaderSize, audioFrameHeaderSize + len),
    );

    _log('[AUDIO] Frame seq=$seq len=$len');
    _recordedFrames.add(payload);
    _framesController.add(payload);
  }

  void _onCtrlNotify(List<int> value) {
    if (value.isEmpty) return;

    switch (value[0]) {
      case audioStatusRecording:
        _log('[AUDIO] Firmware: RECORDING');
        break;
      case audioStatusStopped:
        _log('[AUDIO] Firmware: STOPPED');
        break;
      case audioStatusError:
        _log('[AUDIO] Firmware: ERROR');
        _setState(AudioStreamState.error);
        break;
      default:
        _log('[AUDIO] Unknown ctrl status: 0x${value[0].toRadixString(16)}');
    }
  }

  // -------------------------------------------------------------------------
  // Cleanup
  // -------------------------------------------------------------------------

  void detach() {
    _dataNotifySub?.cancel();
    _dataNotifySub = null;
    _ctrlNotifySub?.cancel();
    _ctrlNotifySub = null;
    _dataChar = null;
    _ctrlChar = null;
    _setState(AudioStreamState.idle);
  }

  void dispose() {
    detach();
    _stateController.close();
    _framesController.close();
    _logController.close();
  }
}
