// ============================================================
//  CONVERGENT — firebase_options.dart
//  ⚠️  THIS IS A PLACEHOLDER FILE
//
//  Replace this file by running:
//    dart pub global activate flutterfire_cli
//    flutterfire configure
//
//  That command will auto-generate the correct values
//  for your Firebase project.
// ============================================================

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError('Unsupported platform');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBmGSczJ0S4-R6RAN_ZFJOx7kR0coVHx6Q',
    appId: '1:678144473208:web:9a1d09923b78257afb558d',
    messagingSenderId: '678144473208',
    projectId: 'convergent-scanner',
    authDomain: 'convergent-scanner.firebaseapp.com',
    storageBucket: 'convergent-scanner.firebasestorage.app',
  );

  // ⚠️  Replace ALL values below with your real Firebase config

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB4-b6SzEyhomxF-lpmrSBJpk3Kc8DpfUg',
    appId: '1:678144473208:android:47b9ef9440d140b1fb558d',
    messagingSenderId: '678144473208',
    projectId: 'convergent-scanner',
    storageBucket: 'convergent-scanner.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBgenWL9BwJyEvtfJWz7be8cjE6L6h23X8',
    appId: '1:678144473208:ios:dff1f0c48c3f6219fb558d',
    messagingSenderId: '678144473208',
    projectId: 'convergent-scanner',
    storageBucket: 'convergent-scanner.firebasestorage.app',
    iosBundleId: 'com.example.convergent',
  );

}