import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'services/ble_audio_service.dart';

// ---------------------------------------------------------------------------
// AudioTab – BLE audio recording and playback
// ---------------------------------------------------------------------------

class AudioTab extends StatefulWidget {
  /// Pass [device] when a BLE device is already connected by the Image tab,
  /// so the audio service can be attached to the same connection.
  final BluetoothDevice? connectedDevice;

  const AudioTab({super.key, this.connectedDevice});

  @override
  State<AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends State<AudioTab>
    with AutomaticKeepAliveClientMixin {
  final BleAudioService _audio = BleAudioService();
  final AudioPlayer _player = AudioPlayer();

  final List<String> _logs = [];
  final ScrollController _logScroll = ScrollController();

  AudioStreamState _state = AudioStreamState.idle;
  bool _attaching = false;

  // Playback state
  bool _playing = false;
  Duration _playPosition = Duration.zero;
  Duration _playDuration = Duration.zero;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playerStateSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    _audio.stateStream.listen((s) => setState(() => _state = s));
    _audio.logStream.listen(_addLog);

    _positionSub = _player.positionStream.listen((p) {
      setState(() => _playPosition = p);
    });
    _durationSub = _player.durationStream.listen((d) {
      if (d != null) setState(() => _playDuration = d);
    });
    _playerStateSub = _player.playerStateStream.listen((ps) {
      setState(() => _playing = ps.playing);
    });

    // Auto-attach if a device is already connected
    if (widget.connectedDevice != null) {
      _attachToDevice(widget.connectedDevice!);
    }
  }

  @override
  void didUpdateWidget(AudioTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newDevice = widget.connectedDevice;
    final oldDevice = oldWidget.connectedDevice;
    if (newDevice != null && newDevice != oldDevice) {
      _attachToDevice(newDevice);
    } else if (newDevice == null && oldDevice != null) {
      _audio.detach();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    _audio.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // BLE
  // -------------------------------------------------------------------------

  Future<void> _attachToDevice(BluetoothDevice device) async {
    if (_attaching) return;
    setState(() => _attaching = true);
    _addLog('[APP] Attaching audio service to ${device.platformName}...');
    try {
      await _audio.attach(device);
      _addLog('[APP] Audio service attached');
    } catch (e) {
      _addLog('[APP] Attach error: $e');
    } finally {
      setState(() => _attaching = false);
    }
  }

  Future<void> _startRecording() async {
    _addLog('[APP] Starting recording...');
    try {
      await _audio.startRecording();
    } catch (e) {
      _addLog('[APP] Start recording error: $e');
    }
  }

  Future<void> _stopRecording() async {
    _addLog('[APP] Stopping recording...');
    try {
      await _audio.stopRecording();
      // Stop any ongoing playback from a previous session
      await _player.stop();
      await _player.seek(Duration.zero);
      setState(() {
        _playPosition = Duration.zero;
        _playDuration = Duration.zero;
      });
    } catch (e) {
      _addLog('[APP] Stop recording error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Playback
  // -------------------------------------------------------------------------

  Future<void> _playRecording() async {
    if (_audio.recordedFrameCount == 0) {
      _addLog('[APP] No audio data to play');
      return;
    }

    try {
      _addLog('[PLAY] Building WAV from ${_audio.recordedFrameCount} frames '
          '(~${_audio.recordedDurationSeconds.toStringAsFixed(1)} s)...');

      final wavBytes = _audio.buildWavFromRecording();

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/audio_recording.wav');
      await file.writeAsBytes(wavBytes);
      _addLog('[PLAY] WAV written: ${file.path} (${wavBytes.length} bytes)');

      await _player.setFilePath(file.path);
      await _player.seek(Duration.zero);
      await _player.play();
      _addLog('[PLAY] Playback started');
    } catch (e) {
      _addLog('[PLAY] Error: $e');
    }
  }

  Future<void> _pauseOrResume() async {
    if (_player.playing) {
      await _player.pause();
      _addLog('[PLAY] Paused');
    } else {
      await _player.play();
      _addLog('[PLAY] Resumed');
    }
  }

  Future<void> _seekTo(double fraction) async {
    if (_playDuration == Duration.zero) return;
    final pos = Duration(
        milliseconds: (fraction * _playDuration.inMilliseconds).toInt());
    await _player.seek(pos);
  }

  // -------------------------------------------------------------------------
  // Logs
  // -------------------------------------------------------------------------

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 500) _logs.removeAt(0);
    });
  }

  void _copyLogs() {
    Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Logs copied'), duration: Duration(seconds: 2)),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isReady = _state == AudioStreamState.ready ||
        _state == AudioStreamState.stopped;
    final isRecording = _state == AudioStreamState.recording;
    final hasStopped = _state == AudioStreamState.stopped;
    final hasFrames  = _audio.recordedFrameCount > 0;

    final sliderValue = _playDuration.inMilliseconds > 0
        ? (_playPosition.inMilliseconds / _playDuration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Connection status ──────────────────────────────────────────────
        _SectionCard(
          title: 'Audio Service',
          icon: Icons.mic,
          trailing: _buildStateChip(),
          children: [
            if (_state == AudioStreamState.idle)
              _attaching
                  ? const Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Attaching…'),
                      ],
                    )
                  : Text(
                      widget.connectedDevice == null
                          ? 'Connect to a device on the Image tab first.'
                          : 'Tap Attach to enable audio service.',
                      style: theme.textTheme.bodySmall,
                    ),
            if (_state == AudioStreamState.idle &&
                widget.connectedDevice != null &&
                !_attaching)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  onPressed: () =>
                      _attachToDevice(widget.connectedDevice!),
                  icon: const Icon(Icons.link),
                  label: const Text('Attach Audio Service'),
                ),
              ),
            if (_state == AudioStreamState.error)
              Text('Error connecting to audio service.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.red)),
          ],
        ),

        const SizedBox(height: 12),

        // ── Record controls ───────────────────────────────────────────────
        if (isReady || isRecording)
          _SectionCard(
            title: 'Record',
            icon: Icons.fiber_manual_record,
            children: [
              if (isRecording) ...[
                Row(
                  children: [
                    const Icon(Icons.circle, color: Colors.red, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'Recording… '
                      '${_audio.recordedFrameCount} frames '
                      '(~${_audio.recordedDurationSeconds.toStringAsFixed(1)} s)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _stopRecording,
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.red),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Recording'),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: isReady ? _startRecording : null,
                  icon: const Icon(Icons.mic),
                  label: const Text('Start Recording'),
                ),
                if (hasStopped)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Last recording: '
                      '${_audio.recordedFrameCount} frames '
                      '(~${_audio.recordedDurationSeconds.toStringAsFixed(1)} s)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),

        const SizedBox(height: 12),

        // ── Playback ──────────────────────────────────────────────────────
        if (hasFrames && !isRecording)
          _SectionCard(
            title: 'Playback',
            icon: Icons.play_circle_outline,
            children: [
              // Slider
              Slider(
                value: sliderValue,
                onChanged: _playDuration.inMilliseconds > 0
                    ? (v) => _seekTo(v)
                    : null,
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_playPosition),
                        style: theme.textTheme.labelSmall),
                    Text(_formatDuration(_playDuration),
                        style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Play / Pause
                  IconButton.filled(
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    tooltip: _playing ? 'Pause' : 'Play',
                    onPressed: _playing ? _pauseOrResume : _playRecording,
                  ),
                  const SizedBox(width: 12),
                  // Stop
                  IconButton.outlined(
                    icon: const Icon(Icons.stop),
                    tooltip: 'Stop',
                    onPressed: () async {
                      await _player.stop();
                      await _player.seek(Duration.zero);
                    },
                  ),
                ],
              ),
            ],
          ),

        const SizedBox(height: 12),

        // ── Log ───────────────────────────────────────────────────────────
        _SectionCard(
          title: 'Log (${_logs.length})',
          icon: Icons.terminal,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy logs',
                onPressed: _logs.isEmpty ? null : _copyLogs,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Clear logs',
                onPressed: _logs.isEmpty
                    ? null
                    : () => setState(() => _logs.clear()),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          children: [
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectionArea(
                child: ListView.builder(
                  controller: _logScroll,
                  padding: const EdgeInsets.all(8),
                  reverse: true,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final idx = _logs.length - 1 - i;
                    return Text(
                      _logs[idx],
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.4,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Widget _buildStateChip() {
    final (label, color) = switch (_state) {
      AudioStreamState.idle       => ('Disconnected', Colors.grey),
      AudioStreamState.connecting => ('Connecting…', Colors.orange),
      AudioStreamState.ready      => ('Ready', Colors.green),
      AudioStreamState.recording  => ('Recording', Colors.red),
      AudioStreamState.stopped    => ('Stopped', Colors.blue),
      AudioStreamState.error      => ('Error', Colors.red),
    };
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// ---------------------------------------------------------------------------
// Reusable section card (same style as main.dart)
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? trailing;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}
