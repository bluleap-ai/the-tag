import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'services/ble_image_transfer.dart';
import 'services/find_my_device_service.dart';
import 'services/image_converter.dart';
import 'pages/find_my_device_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final findMyService = FindMyDeviceService();
  await findMyService.load();
  runApp(VeeaTagApp(findMyService: findMyService));
}

class VeeaTagApp extends StatelessWidget {
  final FindMyDeviceService findMyService;

  const VeeaTagApp({super.key, required this.findMyService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Veea Tag',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A1A2E),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A1A2E),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(findMyService: findMyService),
    );
  }
}

class HomePage extends StatefulWidget {
  final FindMyDeviceService findMyService;

  const HomePage({super.key, required this.findMyService});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleImageTransfer _ble = BleImageTransfer();
  final ImagePicker _picker = ImagePicker();
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  TransferState _bleState = TransferState.idle;
  double _progress = 0;
  bool _scanning = false;
  List<ScanResult> _scanResults = [];

  Uint8List? _originalImageBytes;
  img.Image? _previewImage;
  Uint8List? _convertedBuffer;
  bool _converting = false;

  @override
  void initState() {
    super.initState();
    _ble.stateStream.listen((s) => setState(() => _bleState = s));
    _ble.progressStream.listen((p) => setState(() => _progress = p));
    _ble.logStream.listen((msg) {
      setState(() {
        _logs.add(msg);
        if (_logs.length > 500) _logs.removeAt(0);
      });
    });
  }

  @override
  void dispose() {
    _ble.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _scanResults = [];
    });
    _addLog('[APP] Scan requested by user');
    try {
      final results = await _ble.scan();
      setState(() => _scanResults = results);
      _addLog('[APP] Scan results: ${results.length} device(s)');
    } catch (e) {
      _addLog('[APP] Scan error: $e');
    } finally {
      setState(() => _scanning = false);
    }
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    _addLog('[APP] User selected device: "${device.platformName}" (${device.remoteId})');
    try {
      await _ble.connect(device);
      // Track this device in the Find My Device service.
      final match = _scanResults.where(
        (r) => r.device.remoteId == device.remoteId,
      );
      final rssi = match.isNotEmpty ? match.first.rssi : 0;
      await widget.findMyService.upsert(TrackedDevice(
        address: device.remoteId.toString(),
        name: device.platformName.isNotEmpty ? device.platformName : 'the-tag',
        lastSeen: DateTime.now(),
        lastRssi: rssi,
      ));
    } catch (e) {
      _addLog('[APP] Connect error: $e');
    }
  }

  Future<void> _pickImage() async {
    _addLog('[APP] Opening gallery picker...');
    final xfile = await _picker.pickImage(source: ImageSource.gallery);
    if (xfile == null) {
      _addLog('[APP] Gallery picker cancelled');
      return;
    }

    _addLog('[APP] Image selected: ${xfile.name}');
    final bytes = await xfile.readAsBytes();
    _addLog('[APP] Image loaded: ${bytes.length} bytes');
    setState(() {
      _originalImageBytes = bytes;
      _previewImage = null;
      _convertedBuffer = null;
    });

    _convertImage(bytes);
  }

  Future<void> _takePhoto() async {
    _addLog('[APP] Opening camera...');
    final xfile = await _picker.pickImage(source: ImageSource.camera);
    if (xfile == null) {
      _addLog('[APP] Camera cancelled');
      return;
    }

    _addLog('[APP] Photo taken: ${xfile.name}');
    final bytes = await xfile.readAsBytes();
    _addLog('[APP] Photo loaded: ${bytes.length} bytes');
    setState(() {
      _originalImageBytes = bytes;
      _previewImage = null;
      _convertedBuffer = null;
    });

    _convertImage(bytes);
  }

  void _convertImage(Uint8List bytes) {
    setState(() => _converting = true);
    _addLog('[CONV] Starting conversion (input: ${bytes.length} bytes)');
    _addLog('[CONV] Target: ${epdWidth}x$epdHeight, 4-color, 2bpp');

    final sw = Stopwatch()..start();
    Future.microtask(() {
      try {
        final result = convertImageForEpd(bytes);
        final elapsed = sw.elapsedMilliseconds;
        setState(() {
          _previewImage = result.preview;
          _convertedBuffer = result.buffer;
          _converting = false;
        });
        _addLog('[CONV] Done in ${elapsed}ms -> ${result.buffer.length} bytes');
        _addLog('[CONV] First 8 bytes: ${result.buffer.take(8).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
      } catch (e, st) {
        setState(() => _converting = false);
        _addLog('[CONV] ERROR: $e');
        _addLog('[CONV] Stack: ${st.toString().split('\n').take(3).join(' | ')}');
      }
    });
  }

  Future<void> _sendImage() async {
    if (_convertedBuffer == null) {
      _addLog('[APP] Send requested but no converted image');
      return;
    }
    _addLog('[APP] Send requested: ${_convertedBuffer!.length} bytes');
    try {
      await _ble.sendImage(_convertedBuffer!);
    } catch (e) {
      _addLog('[APP] Send error: $e');
    }
  }

  void _copyLogs() {
    final text = _logs.join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_logs.length} log lines to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clearLogs() {
    setState(() => _logs.clear());
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add('${_ts()} $msg');
      if (_logs.length > 500) _logs.removeAt(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = _bleState != TransferState.idle &&
        _bleState != TransferState.connecting;
    final isBusy = _bleState == TransferState.sending ||
        _bleState == TransferState.displaying;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Veea Tag'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.location_on_outlined),
            tooltip: 'Find My Device',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FindMyDevicePage(
                  findMyService: widget.findMyService,
                  ble: _ble,
                ),
              ),
            ),
          ),
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              tooltip: 'Disconnect',
              onPressed: isBusy ? null : () => _ble.disconnect(),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // --- BLE Connection ---
            _SectionCard(
              title: 'BLE Connection',
              icon: Icons.bluetooth,
              trailing: _buildStatusChip(),
              children: [
                if (!isConnected) ...[
                  FilledButton.icon(
                    onPressed: _scanning ? null : _startScan,
                    icon: _scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(_scanning ? 'Scanning...' : 'Scan for Devices'),
                  ),
                  if (_scanResults.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        children: _scanResults.map((r) {
                          final name = r.device.platformName.isNotEmpty
                              ? r.device.platformName
                              : 'Unknown';
                          return ListTile(
                            leading: const Icon(Icons.devices),
                            title: Text(name),
                            subtitle:
                                Text(r.device.remoteId.toString()),
                            trailing:
                                Text('${r.rssi} dBm'),
                            onTap: () => _connectDevice(r.device),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          );
                        }).toList(),
                      ),
                    ),
                ] else ...[
                  Row(
                    children: [
                      const Icon(Icons.check_circle,
                          color: Colors.green, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Connected to ${_ble.connectedDevice?.platformName ?? "device"}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),

            const SizedBox(height: 12),

            // --- Image Selection ---
            _SectionCard(
              title: 'Image',
              icon: Icons.image,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Gallery'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _takePhoto,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                      ),
                    ),
                  ],
                ),
                if (_converting)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_originalImageBytes != null && _previewImage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Text('Original',
                                  style: theme.textTheme.labelSmall),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  _originalImageBytes!,
                                  width: 152,
                                  height: 152,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.arrow_forward),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text('E-Ink Preview',
                                  style: theme.textTheme.labelSmall),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  Uint8List.fromList(
                                      img.encodePng(_previewImage!)),
                                  width: 152,
                                  height: 152,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // --- Transfer ---
            if (isConnected && _convertedBuffer != null)
              _SectionCard(
                title: 'Transfer',
                icon: Icons.send,
                children: [
                  if (isBusy) ...[
                    LinearProgressIndicator(
                      value: _bleState == TransferState.sending
                          ? _progress
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _bleState == TransferState.sending
                          ? 'Sending: ${(_progress * 100).toInt()}%'
                          : 'Refreshing display...',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: _sendImage,
                      icon: const Icon(Icons.send),
                      label: Text(
                          'Send to Display (${_convertedBuffer!.length} bytes)'),
                    ),
                    if (_bleState == TransferState.done)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 18),
                            const SizedBox(width: 6),
                            Text('Image displayed successfully!',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.green)),
                          ],
                        ),
                      ),
                    if (_bleState == TransferState.error)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.error,
                                color: Colors.red, size: 18),
                            const SizedBox(width: 6),
                            Text('Transfer failed',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: Colors.red)),
                          ],
                        ),
                      ),
                  ],
                ],
              ),

            const SizedBox(height: 12),

            // --- Log ---
            _SectionCard(
              title: 'Log (${_logs.length})',
              icon: Icons.terminal,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy all logs',
                    onPressed: _logs.isEmpty ? null : _copyLogs,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Clear logs',
                    onPressed: _logs.isEmpty ? null : _clearLogs,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              children: [
                Container(
                  height: 220,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _logScrollController,
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
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    final (label, color) = switch (_bleState) {
      TransferState.idle => ('Disconnected', Colors.grey),
      TransferState.connecting => ('Connecting...', Colors.orange),
      TransferState.connected => ('Connected', Colors.green),
      TransferState.sending => ('Sending', Colors.blue),
      TransferState.displaying => ('Displaying', Colors.purple),
      TransferState.done => ('Done', Colors.green),
      TransferState.error => ('Error', Colors.red),
    };
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

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
