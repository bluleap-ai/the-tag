import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/find_my_device_service.dart';
import '../services/ble_image_transfer.dart';

/// The URL for Google's Find My Device web application.
const String _kGoogleFindMyDeviceUrl = 'https://findmydevice.google.com';

/// A page that lists all tracked tag devices and provides:
///  - Last-seen timestamp and signal strength per device.
///  - A "Find Device" button that connects over BLE and triggers a LED blink
///    on the physical tag so the user can locate it.
///  - A direct link to Google's Find My Device web service.
class FindMyDevicePage extends StatefulWidget {
  final FindMyDeviceService findMyService;
  final BleImageTransfer ble;

  const FindMyDevicePage({
    super.key,
    required this.findMyService,
    required this.ble,
  });

  @override
  State<FindMyDevicePage> createState() => _FindMyDevicePageState();
}

class _FindMyDevicePageState extends State<FindMyDevicePage> {
  late StreamSubscription<List<TrackedDevice>> _sub;
  List<TrackedDevice> _devices = [];

  // Address of the device currently being "found" (LED blinking).
  String? _findingAddress;

  @override
  void initState() {
    super.initState();
    _devices = widget.findMyService.devices;
    _sub = widget.findMyService.stream.listen((list) {
      if (mounted) setState(() => _devices = list);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  Future<void> _openGoogleFindMyDevice() async {
    final uri = Uri.parse(_kGoogleFindMyDeviceUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open Google Find My Device'),
          ),
        );
      }
    }
  }

  Future<void> _findDevice(TrackedDevice device) async {
    setState(() => _findingAddress = device.address);

    try {
      await widget.ble.sendFindCommand();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ringing "${device.name}"…'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Find failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _findingAddress = null);
    }
  }

  Future<void> _removeDevice(TrackedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text(
            'Remove "${device.name}" from your tracked devices? This will not affect the physical tag.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.findMyService.remove(device.address);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = widget.ble.state != TransferState.idle &&
        widget.ble.state != TransferState.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find My Device'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Google Find My Device banner ---
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Card(
                elevation: 0,
                color: theme.colorScheme.primaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          color: theme.colorScheme.onPrimaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Google Find My Device',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Access the full Find My Device network',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _openGoogleFindMyDevice,
                        child: const Text('Open'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // --- Fast Pair info ---
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.bluetooth_connected, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'The-Tag broadcasts Google Fast Pair (UUID 0xFE2C). '
                          'Android phones will automatically prompt to pair when the tag is nearby.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // --- Tracked device list header ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text('Tracked Devices (${_devices.length})',
                      style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (_devices.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Clear all?'),
                            content: const Text(
                                'Remove all tracked devices from this list?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await widget.findMyService.clearAll();
                        }
                      },
                      child: const Text('Clear all'),
                    ),
                ],
              ),
            ),

            // --- Device list ---
            Expanded(
              child: _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.location_searching,
                              size: 48,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.3)),
                          const SizedBox(height: 12),
                          Text(
                            'No devices tracked yet',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Connect to a tag on the main screen to add it here.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.4),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      itemCount: _devices.length,
                      itemBuilder: (_, i) =>
                          _DeviceTile(
                            device: _devices[i],
                            isConnected: isConnected &&
                                widget.ble.connectedDevice?.remoteId
                                        .toString() ==
                                    _devices[i].address,
                            isFinding:
                                _findingAddress == _devices[i].address,
                            onFind: () => _findDevice(_devices[i]),
                            onRemove: () => _removeDevice(_devices[i]),
                          ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final TrackedDevice device;
  final bool isConnected;
  final bool isFinding;
  final VoidCallback onFind;
  final VoidCallback onRemove;

  const _DeviceTile({
    required this.device,
    required this.isConnected,
    required this.isFinding,
    required this.onFind,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSeenStr = FindMyDeviceService.formatLastSeen(device.lastSeen);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Device icon + status dot
            Stack(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.nfc,
                      size: 24, color: theme.colorScheme.primary),
                ),
                if (isConnected)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: theme.colorScheme.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // Name + last seen
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.access_time,
                          size: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5)),
                      const SizedBox(width: 3),
                      Text(lastSeenStr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          )),
                      const SizedBox(width: 8),
                      Icon(Icons.signal_cellular_alt,
                          size: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5)),
                      const SizedBox(width: 3),
                      Text('${device.lastRssi} dBm',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          )),
                    ],
                  ),
                ],
              ),
            ),
            // Action buttons
            if (isFinding)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              IconButton(
                icon: const Icon(Icons.volume_up, size: 20),
                tooltip: 'Find device (blink LED)',
                onPressed: isConnected ? onFind : null,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Remove from list',
                onPressed: onRemove,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
