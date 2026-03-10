import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_tag_app/services/find_my_device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ---------------------------------------------------------------------------
  // TrackedDevice
  // ---------------------------------------------------------------------------

  group('TrackedDevice', () {
    test('serialises to and from JSON', () {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      const device = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime(2024, 6, 15, 12, 0, 0),
        lastRssi: -65,
      );

      final json = device.toJson();
      final roundTripped = TrackedDevice.fromJson(json);

      expect(roundTripped.address, device.address);
      expect(roundTripped.name, device.name);
      expect(roundTripped.lastSeen, now);
      expect(roundTripped.lastRssi, device.lastRssi);
    });

    test('equality is by address', () {
      final d1 = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'tag-1',
        lastSeen: DateTime.now(),
        lastRssi: -70,
      );
      final d2 = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'tag-renamed',
        lastSeen: DateTime.now(),
        lastRssi: -60,
      );
      expect(d1, equals(d2));
    });

    test('copyWith replaces only specified fields', () {
      final original = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'old-name',
        lastSeen: DateTime(2024, 1, 1),
        lastRssi: -80,
      );
      final updated = original.copyWith(name: 'new-name', lastRssi: -50);

      expect(updated.address, original.address);
      expect(updated.name, 'new-name');
      expect(updated.lastRssi, -50);
      expect(updated.lastSeen, original.lastSeen);
    });
  });

  // ---------------------------------------------------------------------------
  // FindMyDeviceService
  // ---------------------------------------------------------------------------

  group('FindMyDeviceService', () {
    late FindMyDeviceService service;

    setUp(() {
      service = FindMyDeviceService();
    });

    tearDown(() {
      service.dispose();
    });

    test('starts empty after load with no prefs', () async {
      await service.load();
      expect(service.devices, isEmpty);
    });

    test('upsert adds a new device', () async {
      await service.load();

      final device = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime.now(),
        lastRssi: -65,
      );

      await service.upsert(device);
      expect(service.devices.length, 1);
      expect(service.devices.first.address, device.address);
    });

    test('upsert updates an existing device', () async {
      await service.load();

      final original = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime(2024, 1, 1),
        lastRssi: -80,
      );
      await service.upsert(original);

      final updated = original.copyWith(
        lastSeen: DateTime(2024, 6, 15),
        lastRssi: -55,
      );
      await service.upsert(updated);

      expect(service.devices.length, 1);
      expect(service.devices.first.lastRssi, -55);
    });

    test('devices are sorted most-recently-seen first', () async {
      await service.load();

      final older = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:01',
        name: 'old-tag',
        lastSeen: DateTime(2024, 1, 1),
        lastRssi: -80,
      );
      final newer = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:02',
        name: 'new-tag',
        lastSeen: DateTime(2024, 6, 15),
        lastRssi: -55,
      );

      await service.upsert(older);
      await service.upsert(newer);

      expect(service.devices.first.address, newer.address);
      expect(service.devices.last.address, older.address);
    });

    test('remove deletes the device', () async {
      await service.load();

      final device = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime.now(),
        lastRssi: -65,
      );
      await service.upsert(device);
      await service.remove(device.address);

      expect(service.devices, isEmpty);
    });

    test('clearAll removes all devices', () async {
      await service.load();

      for (int i = 0; i < 3; i++) {
        await service.upsert(TrackedDevice(
          address: 'AA:BB:CC:DD:EE:0$i',
          name: 'tag-$i',
          lastSeen: DateTime.now(),
          lastRssi: -60 - i,
        ));
      }

      await service.clearAll();
      expect(service.devices, isEmpty);
    });

    test('devices are persisted across service instances', () async {
      final device = TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime(2024, 6, 15, 12),
        lastRssi: -65,
      );

      // First instance: add device.
      final s1 = FindMyDeviceService();
      await s1.load();
      await s1.upsert(device);
      s1.dispose();

      // Second instance: should reload from prefs.
      final s2 = FindMyDeviceService();
      await s2.load();

      expect(s2.devices.length, 1);
      expect(s2.devices.first.address, device.address);
      expect(s2.devices.first.lastRssi, device.lastRssi);
      s2.dispose();
    });

    test('stream emits on upsert', () async {
      await service.load();

      final emissions = <List<TrackedDevice>>[];
      final sub = service.stream.listen(emissions.add);

      await service.upsert(TrackedDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'the-tag',
        lastSeen: DateTime.now(),
        lastRssi: -65,
      ));

      await Future.delayed(Duration.zero);
      expect(emissions.length, 1);
      expect(emissions.first.length, 1);

      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  // FindMyDeviceService.formatLastSeen
  // ---------------------------------------------------------------------------

  group('FindMyDeviceService.formatLastSeen', () {
    test('just now for under a minute', () {
      final ts = DateTime.now().subtract(const Duration(seconds: 30));
      expect(FindMyDeviceService.formatLastSeen(ts), 'Just now');
    });

    test('minutes ago', () {
      final ts = DateTime.now().subtract(const Duration(minutes: 5));
      expect(FindMyDeviceService.formatLastSeen(ts), '5 minutes ago');
    });

    test('1 minute ago (singular)', () {
      final ts = DateTime.now().subtract(const Duration(minutes: 1));
      expect(FindMyDeviceService.formatLastSeen(ts), '1 minute ago');
    });

    test('hours ago', () {
      final ts = DateTime.now().subtract(const Duration(hours: 3));
      expect(FindMyDeviceService.formatLastSeen(ts), '3 hours ago');
    });

    test('yesterday', () {
      final ts = DateTime.now().subtract(const Duration(days: 1));
      expect(FindMyDeviceService.formatLastSeen(ts), 'Yesterday');
    });

    test('days ago', () {
      final ts = DateTime.now().subtract(const Duration(days: 5));
      expect(FindMyDeviceService.formatLastSeen(ts), '5 days ago');
    });
  });
}
