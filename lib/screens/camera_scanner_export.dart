// Conditional export — use this file in dashboards instead of
// importing camera_scanner_screen.dart directly.
//
// On mobile (dart:io available)  → real camera scanner
// On web    (dart:html available) → stub screen
export 'camera_scanner_screen.dart'
    if (dart.library.html) 'camera_scanner_screen_web.dart';