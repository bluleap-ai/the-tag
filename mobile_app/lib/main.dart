import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_tab.dart';
import 'services/ble_image_transfer.dart';
import 'services/image_converter.dart';
import 'models/device_type.dart';

void main() {
  runApp(const VeeaTagApp());
}

class VeeaTagApp extends StatelessWidget {
  const VeeaTagApp({super.key});

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
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _TabShell(tabController: _tabController);
  }
}

// ---------------------------------------------------------------------------
// Shell that owns the BLE connection and hands the device to both tabs
// ---------------------------------------------------------------------------

class _TabShell extends StatefulWidget {
  final TabController tabController;
  const _TabShell({required this.tabController});

  @override
  State<_TabShell> createState() => _TabShellState();
}

class _TabShellState extends State<_TabShell> {
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

  // Received images from camera
  final List<Uint8List> _receivedImages = [];
  StreamSubscription? _omiImageSub;

  @override
  void initState() {
    super.initState();
    _ble.stateStream.listen((s) {
      setState(() => _bleState = s);
      // Subscribe to omiGlass image stream when connected to camera device
      if (s == TransferState.connected && _ble.deviceType == DeviceType.camera) {
        _subscribeToOmiImages();
      }
    });
    _ble.progressStream.listen((p) => setState(() => _progress = p));
    _ble.logStream.listen((msg) {
      setState(() {
        _logs.add(msg);
        if (_logs.length > 500) _logs.removeAt(0);
      });
    });
  }

  void _subscribeToOmiImages() {
    _omiImageSub?.cancel();
    final stream = _ble.omiImageStream;
    if (stream != null) {
      _omiImageSub = stream.listen((imageData) {
        setState(() {
          _receivedImages.insert(0, imageData); // Add to front (newest first)
          if (_receivedImages.length > 50) {
            _receivedImages.removeLast(); // Keep max 50 images
          }
        });
        _addLog('[APP] Received image from camera: ${imageData.length} bytes');
      });
    }
  }

  @override
  void dispose() {
    _omiImageSub?.cancel();
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

  Future<bool> _requestBlePermissions() async {
    // Android 12+ (API 31+) requires runtime grants for BLE + location
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final denied = statuses.entries
        .where((e) => !e.value.isGranted)
        .map((e) => e.key.toString())
        .toList();

    if (denied.isNotEmpty) {
      _addLog('[APP] Permission denied: ${denied.join(', ')}');

      // If permanently denied, guide user to settings
      final permanent = statuses.entries
          .where((e) => e.value.isPermanentlyDenied)
          .toList();
      if (permanent.isNotEmpty && mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Bluetooth Permission Required'),
            content: const Text(
              'Bluetooth and Location permissions are permanently denied.\n\n'
              'Please enable them in App Settings → Permissions.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
      }
      return false;
    }

    _addLog('[APP] All BLE permissions granted');
    return true;
  }

  Future<void> _startScan() async {
    // Always check/request permissions first
    if (!await _requestBlePermissions()) return;

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

  void _selectReceivedImage(Uint8List imageBytes) {
    _addLog('[APP] Selected received image: ${imageBytes.length} bytes');
    setState(() {
      _originalImageBytes = imageBytes;
      _previewImage = null;
      _convertedBuffer = null;
    });
    _convertImage(imageBytes);
  }

  Future<void> _showReceivedImagesGallery() async {
    if (_receivedImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No images received yet. Connect to camera device to receive images.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    await showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.photo_library),
                    const SizedBox(width: 8),
                    Text(
                      'Received Images (${_receivedImages.length})',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Save all images',
                      onPressed: () async {
                        for (int i = 0; i < _receivedImages.length; i++) {
                          await _saveImageToDownloads(_receivedImages[i], i);
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _receivedImages.length,
                  itemBuilder: (context, index) {
                    final imageBytes = _receivedImages[index];
                    return InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        _selectReceivedImage(imageBytes);
                      },
                      onLongPress: () => _saveImageToDownloads(imageBytes, index),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                imageBytes,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: double.infinity,
                              ),
                            ),
                            Positioned(
                              bottom: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _saveImageToDownloads(imageBytes, index),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Icon(
                                    Icons.download,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _saveImageToDownloads(Uint8List imageBytes, int index) async {
    try {
      // Request storage permission on Android
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          // Android 13+ doesn't need storage permission for app-specific dirs
          // Try anyway with getExternalStorageDirectory
        }
      }

      // Save to app's external storage (visible in Files app)
      Directory? dir;
      if (Platform.isAndroid) {
        dir = await getExternalStorageDirectory();
        // Navigate to Downloads
        final downloads = Directory('${dir?.parent.parent.parent.parent.path}/Download');
        if (await downloads.exists()) {
          dir = downloads;
        }
      } else {
        dir = await getApplicationDocumentsDirectory();
      }

      if (dir == null) {
        _addLog('[APP] Cannot find storage directory');
        return;
      }

      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/veea_img_$ts.png');
      await file.writeAsBytes(imageBytes);

      _addLog('[APP] Saved image to ${file.path}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${file.path.split('/').last}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      _addLog('[APP] Save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
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
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              tooltip: 'Disconnect',
              onPressed: isBusy ? null : () => _ble.disconnect(),
            ),
        ],
        bottom: TabBar(
          controller: widget.tabController,
          tabs: const [
            Tab(icon: Icon(Icons.image), text: 'Image'),
            Tab(icon: Icon(Icons.mic), text: 'Audio'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: widget.tabController,
          children: [
            // ── Image tab ────────────────────────────────────────────────
            _buildImageTab(theme, isConnected, isBusy),

            // ── Audio tab ────────────────────────────────────────────────
            AudioTab(
              connectedDevice: _ble.connectedDevice,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageTab(
      ThemeData theme, bool isConnected, bool isBusy) {
    return ListView(
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
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _showReceivedImagesGallery,
                    icon: Badge(
                      label: Text('${_receivedImages.length}'),
                      isLabelVisible: _receivedImages.isNotEmpty,
                      child: const Icon(Icons.camera_enhance),
                    ),
                    label: const Text('Received'),
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
      backgroundColor: color.withAlpha(38),
      side: BorderSide(color: color.withAlpha(76)),
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
            color: theme.colorScheme.outlineVariant.withAlpha(128)),
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
                if (trailing != null) trailing!,
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
