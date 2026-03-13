// ---------------------------------------------------------------------------
// LC3 Decoder – Dart FFI wrapper around the native liblc3 bridge
// ---------------------------------------------------------------------------

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Opaque native handle (pointer to Lc3DecoderCtx in C).
final class Lc3DecoderCtx extends Opaque {}

// C function signatures
typedef _CreateNative = Pointer<Lc3DecoderCtx> Function(Int32 dtUs, Int32 srHz);
typedef _CreateDart = Pointer<Lc3DecoderCtx> Function(int dtUs, int srHz);

typedef _FrameSamplesNative = Int32 Function(Pointer<Lc3DecoderCtx>);
typedef _FrameSamplesDart = int Function(Pointer<Lc3DecoderCtx>);

typedef _DecodeNative = Int32 Function(
    Pointer<Lc3DecoderCtx>, Pointer<Uint8>, Int32, Pointer<Int16>);
typedef _DecodeDart = int Function(
    Pointer<Lc3DecoderCtx>, Pointer<Uint8>, int, Pointer<Int16>);

typedef _DestroyNative = Void Function(Pointer<Lc3DecoderCtx>);
typedef _DestroyDart = void Function(Pointer<Lc3DecoderCtx>);

/// High-level LC3 decoder that wraps the native C bridge via `dart:ffi`.
class Lc3Decoder {
  late final DynamicLibrary _lib;
  late final _CreateDart _create;
  late final _FrameSamplesDart _frameSamples;
  late final _DecodeDart _decode;
  late final _DestroyDart _destroy;

  Pointer<Lc3DecoderCtx>? _ctx;
  int _samplesPerFrame = 0;

  /// Frame duration in µs (must match firmware, e.g. 10000 for 10 ms).
  final int dtUs;

  /// Sample rate in Hz (must match firmware, e.g. 16000).
  final int srHz;

  Lc3Decoder({this.dtUs = 10000, this.srHz = 16000}) {
    _lib = _openLibrary();
    _create = _lib
        .lookup<NativeFunction<_CreateNative>>('lc3_decoder_create')
        .asFunction();
    _frameSamples = _lib
        .lookup<NativeFunction<_FrameSamplesNative>>(
            'lc3_decoder_frame_samples')
        .asFunction();
    _decode = _lib
        .lookup<NativeFunction<_DecodeNative>>('lc3_decoder_decode_frame')
        .asFunction();
    _destroy = _lib
        .lookup<NativeFunction<_DestroyNative>>('lc3_decoder_destroy')
        .asFunction();
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('liblc3_decoder.so');
    }
    // iOS / macOS / Linux / Windows can be added here later.
    throw UnsupportedError(
        'LC3 native decoder not available on ${Platform.operatingSystem}');
  }

  /// Initialise the native decoder context.  Must be called before [decode].
  void init() {
    dispose(); // clean up any previous context
    _ctx = _create(dtUs, srHz);
    if (_ctx == null || _ctx == nullptr) {
      throw StateError('Failed to create LC3 decoder (dt=$dtUs sr=$srHz)');
    }
    _samplesPerFrame = _frameSamples(_ctx!);
  }

  /// Number of PCM samples produced per decoded frame.
  int get samplesPerFrame => _samplesPerFrame;

  /// Decode a list of LC3 frames into a single PCM S16 byte buffer suitable
  /// for wrapping in a WAV file.
  ///
  /// Returns the raw PCM bytes (little-endian signed 16-bit, mono).
  Uint8List decodeFrames(List<Uint8List> frames) {
    if (_ctx == null || _ctx == nullptr) {
      throw StateError('Decoder not initialised – call init() first');
    }

    final int bytesPerSample = 2; // S16
    final int framePcmBytes = _samplesPerFrame * bytesPerSample;

    // Allocate native buffers once and reuse per frame.
    // package:ffi calloc properly allocates count × sizeOf<T>() bytes.
    final maxFrameLen = frames.fold<int>(0, (m, f) => f.length > m ? f.length : m);
    final inBuf = calloc<Uint8>(maxFrameLen);
    final outBuf = calloc<Int16>(_samplesPerFrame);

    final result = BytesBuilder(copy: false);

    for (final frame in frames) {
      // Copy LC3 frame into native memory
      final inPtr = inBuf;
      for (int i = 0; i < frame.length; i++) {
        inPtr[i] = frame[i];
      }

      final rc = _decode(_ctx!, inPtr, frame.length, outBuf);
      if (rc != 0) {
        // PLC (packet loss concealment) – pass null input to get comfort noise
        _decode(_ctx!, nullptr, 0, outBuf);
      }

      // Copy decoded PCM to Dart bytes
      final pcmBytes =
          outBuf.cast<Uint8>().asTypedList(framePcmBytes);
      result.add(Uint8List.fromList(pcmBytes));
    }

    calloc.free(inBuf);
    calloc.free(outBuf);

    return result.toBytes();
  }


  /// Release native resources.
  void dispose() {
    if (_ctx != null && _ctx != nullptr) {
      _destroy(_ctx!);
      _ctx = null;
    }
  }
}
