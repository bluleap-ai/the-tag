enum DeviceType {
  eink,    // E-paper display (the-tag)
  camera,  // Camera wearable (veea/omiGlass)
  unknown,
}

extension DeviceTypeExtension on DeviceType {
  String get displayName {
    switch (this) {
      case DeviceType.eink:
        return 'E-ink Display';
      case DeviceType.camera:
        return 'Camera Wearable';
      case DeviceType.unknown:
        return 'Unknown Device';
    }
  }

  String get description {
    switch (this) {
      case DeviceType.eink:
        return 'E-paper display with BLE image transfer';
      case DeviceType.camera:
        return 'Wearable camera with real-time streaming';
      case DeviceType.unknown:
        return 'Device type not detected';
    }
  }
}
