import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A record of a tag device that has been seen by the app.
class TrackedDevice {
  final String address;
  final String name;
  final DateTime lastSeen;
  final int lastRssi;

  const TrackedDevice({
    required this.address,
    required this.name,
    required this.lastSeen,
    required this.lastRssi,
  });

  TrackedDevice copyWith({
    String? address,
    String? name,
    DateTime? lastSeen,
    int? lastRssi,
  }) {
    return TrackedDevice(
      address: address ?? this.address,
      name: name ?? this.name,
      lastSeen: lastSeen ?? this.lastSeen,
      lastRssi: lastRssi ?? this.lastRssi,
    );
  }

  Map<String, dynamic> toJson() => {
        'address': address,
        'name': name,
        'lastSeen': lastSeen.toIso8601String(),
        'lastRssi': lastRssi,
      };

  factory TrackedDevice.fromJson(Map<String, dynamic> json) => TrackedDevice(
        address: json['address'] as String,
        name: json['name'] as String,
        lastSeen: DateTime.parse(json['lastSeen'] as String),
        lastRssi: json['lastRssi'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is TrackedDevice && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

/// Persists and provides access to the list of known tag devices.
///
/// Devices are stored under the SharedPreferences key [_kStorageKey].
/// Call [load] once on startup, then use [upsert] and [remove] to modify
/// the list.  Listen to [stream] for live updates.
class FindMyDeviceService {
  static const String _kStorageKey = 'find_my_device_tracked';

  final _controller = StreamController<List<TrackedDevice>>.broadcast();

  List<TrackedDevice> _devices = [];

  /// Current in-memory list of tracked devices (most-recently-seen first).
  List<TrackedDevice> get devices => List.unmodifiable(_devices);

  /// Stream of tracked device list updates.
  Stream<List<TrackedDevice>> get stream => _controller.stream;

  /// Load persisted devices from SharedPreferences.
  ///
  /// Must be called before any other method.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStorageKey);
    if (raw == null) {
      _devices = [];
      return;
    }

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _devices = list
          .map((e) => TrackedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
      _sortDevices();
    } catch (_) {
      _devices = [];
    }
  }

  /// Add a new device or update the last-seen info for an existing one.
  ///
  /// After saving, the [stream] emits the updated list.
  Future<void> upsert(TrackedDevice device) async {
    final idx = _devices.indexWhere((d) => d.address == device.address);
    if (idx >= 0) {
      _devices[idx] = device;
    } else {
      _devices.add(device);
    }
    _sortDevices();
    await _persist();
    _controller.add(devices);
  }

  /// Remove a tracked device by its BLE address.
  Future<void> remove(String address) async {
    _devices.removeWhere((d) => d.address == address);
    await _persist();
    _controller.add(devices);
  }

  /// Remove all tracked devices.
  Future<void> clearAll() async {
    _devices = [];
    await _persist();
    _controller.add(devices);
  }

  /// Returns a human-readable "last seen" string for the given [device].
  ///
  /// Examples: "Just now", "3 minutes ago", "Yesterday", "5 days ago".
  static String formatLastSeen(DateTime lastSeen) {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m minute${m == 1 ? '' : 's'} ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h hour${h == 1 ? '' : 's'} ago';
    }
    if (diff.inDays == 1) return 'Yesterday';
    final d = diff.inDays;
    return '$d days ago';
  }

  void dispose() {
    _controller.close();
  }

  // ---------------------------------------------------------------------------

  void _sortDevices() {
    _devices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kStorageKey,
      jsonEncode(_devices.map((d) => d.toJson()).toList()),
    );
  }
}
