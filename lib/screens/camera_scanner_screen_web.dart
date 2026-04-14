// Web camera screen — Live camera + Roboflow detection + Tesseract.js OCR
// Used instead of camera_scanner_screen.dart on web builds.
//
// Pipeline:
//   1. Live camera preview via getUserMedia (rear camera preferred)
//   2. User taps "Capture & Scan" to snapshot
//   3. Roboflow API   → detects WHERE the plate is (bounding box)
//   4. Canvas API     → crops the plate region + 15% padding
//   5. Tesseract.js   → reads plate text locally (free, no API cost)
//   6. _fix()/_tryTokens() → corrects OCR errors (same as mobile)
//   7. Auto-search DB → show result or confirm dialog
//
// Free tiers:
//   • Roboflow:     1,000 requests/month (detection only)
//   • Tesseract.js: unlimited (runs locally in browser)

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
// ignore: deprecated_member_use
import 'dart:html' as html;
// ignore: depend_on_referenced_packages
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import '../services/plate_recognizer_service.dart';
import '../services/firestore_service.dart';
import '../services/roboflow_service.dart';
import '../models/vehicle_model.dart';
import '../widgets/vehicle_result_popup.dart';

// ── Philippine plate formats (mirrors camera_scanner_screen.dart) ─
final _rxPlate = RegExp(r'^[A-Z]{3}[0-9]{4}$');
final _rxOld   = RegExp(r'^[A-Z]{3}[0-9]{3}$');
final _rxCS    = RegExp(r'^[A-Z]{2}[0-9]{3,4}[A-Z]?$');

bool _isValid(String s) =>
    _rxPlate.hasMatch(s) || _rxOld.hasMatch(s) || _rxCS.hasMatch(s);

// ── Position-aware OCR correction ────────────────────────────────
String? _fix(String s) {
  const toL = {'0':'O','1':'I','8':'B','5':'S','2':'Z','6':'G','4':'A','7':'T'};
  const toD = {'O':'0','I':'1','B':'8','S':'5','Z':'2','G':'6','Q':'0','A':'4','T':'7'};
  String L(String c) => toL[c] ?? c;
  String D(String c) => toD[c] ?? c;
  bool isLetter(String c) => c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90;
  if (s.length == 7) {
    final f = '${L(s[0])}${L(s[1])}${L(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}${D(s[6])}';
    if (_isValid(f)) return f;
    final l0 = L(s[0]); final l1 = L(s[1]);
    if (isLetter(l0) && isLetter(l1)) {
      final f2 = '$l0$l1${D(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}${L(s[6])}';
      if (_isValid(f2)) return f2;
    }
  }
  if (s.length == 6) {
    final f = '${L(s[0])}${L(s[1])}${L(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}';
    if (_isValid(f)) return f;
    final l0 = L(s[0]); final l1 = L(s[1]);
    if (isLetter(l0) && isLetter(l1)) {
      final f2 = '$l0$l1${D(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}';
      if (_isValid(f2)) return f2;
    }
  }
  return null;
}

// ── Sliding window token extraction ──────────────────────────────
String? _tryTokens(List<({String text, double x, double y, double h})> elements, [Set<String>? dbPlates]) {
  // Sort tokens by Y (top-to-bottom) then X (left-to-right)
  elements.sort((a, b) {
    if ((a.y - b.y).abs() > (a.h * 0.5)) return a.y.compareTo(b.y);
    return a.x.compareTo(b.x);
  });

  final tokens = elements.map((e) => e.text).toList();
  final sortedHeights = elements.map((e) => e.h).toList()..sort();
  final maxHeight = sortedHeights.isEmpty ? 0 : sortedHeights.last;
  final strictThresh = maxHeight * 0.85;
  final mediumThresh = maxHeight * 0.70;

  final eliteTokens = elements.where((e) => e.h >= strictThresh).map((e) => e.text).toList();
  final mediumTokens = elements.where((e) => e.h >= mediumThresh).map((e) => e.text).toList();

  // 1. Try 7-char plates first (priority)
  final p7 = _tryTokensForLen(eliteTokens, 7, dbPlates) ?? _tryTokensForLen(mediumTokens, 7, dbPlates) ?? _tryTokensForLen(tokens, 7, dbPlates);
  if (p7 != null) return p7;
  
  // 2. Try 6-char plates
  final p6 = _tryTokensForLen(eliteTokens, 6, dbPlates) ?? _tryTokensForLen(mediumTokens, 6, dbPlates) ?? _tryTokensForLen(tokens, 6, dbPlates);
  if (p6 != null) return p6;

  return null;
}

String? _tryTokensForLen(List<String> tokens, int len, [Set<String>? dbPlates]) {
  // 1. Exact matches
  for (final token in tokens) {
    if (token.length == len) {
      if (_isValid(token)) return token;
      final fixed = _fix(token);
      if (fixed != null) return fixed;
      final dbMatch = _fuzzySearchDb(token, dbPlates);
      if (dbMatch != null) return dbMatch;
    }
  }

  // 2. Sliding window over tokens
  for (final token in tokens) {
    if (token.length > len) {
      for (int i = 0; i <= token.length - len; i++) {
        final s = token.substring(i, i + len);
        if (_isValid(s)) return s;
        final fixed = _fix(s);
        if (fixed != null) return fixed;
        final dbMatch = _fuzzySearchDb(s, dbPlates);
        if (dbMatch != null) return dbMatch;
      }
    }
  }

  // 3. Joining tokens
  final joined = tokens.where((t) => t.length <= 8).join('');
  if (joined.length >= len) {
    for (int i = 0; i <= joined.length - len; i++) {
      final s = joined.substring(i, i + len);
      if (_isValid(s)) return s;
      final fixed = _fix(s);
      if (fixed != null) return fixed;
      final dbMatch = _fuzzySearchDb(s, dbPlates);
      if (dbMatch != null) return dbMatch;
    }
  }
  return null;
}

/// Fuzzy search DB for a read that almost matches a known plate
String? _fuzzySearchDb(String read, Set<String>? dbPlates) {
  if (dbPlates == null || dbPlates.isEmpty) return null;
  if (dbPlates.contains(read)) return read;
  for (final plate in dbPlates) {
    if ((plate.length - read.length).abs() > 1) continue;
    if (_levenshtein(read, plate) <= 1) return plate;
  }
  return null;
}

int _levenshtein(String s, String t) {
  if (s == t) return 0;
  if (s.isEmpty) return t.length;
  if (t.isEmpty) return s.length;
  List<int> v0 = List<int>.generate(t.length + 1, (i) => i);
  List<int> v1 = List<int>.filled(t.length + 1, 0);
  for (int i = 0; i < s.length; i++) {
    v1[0] = i + 1;
    for (int j = 0; j < t.length; j++) {
      int cost = (s[i] == t[j]) ? 0 : 1;
      v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
    }
    for (int j = 0; j < v0.length; j++) v0[j] = v1[j];
  }
  return v0[t.length];
}

// ── Crop plate region using HTML Canvas ──────────────────────────
Future<String> _cropAndPreprocessPlate(
    Uint8List imageBytes, PlateDetection detection) async {
  final completer = Completer<String>();

  final blob = html.Blob([imageBytes]);
  final blobUrl = html.Url.createObjectUrlFromBlob(blob);
  final img = html.ImageElement();

  img.onLoad.listen((_) {
    final imgW = img.naturalWidth.toDouble();
    final imgH = img.naturalHeight.toDouble();

    final padX = detection.width * 0.15;
    final padY = detection.height * 0.15;

    final left   = ((detection.x - detection.width / 2) - padX).clamp(0, imgW - 1);
    final top    = ((detection.y - detection.height / 2) - padY).clamp(0, imgH - 1);
    final right  = ((detection.x + detection.width / 2) + padX).clamp(0, imgH);
    final bottom = ((detection.y + detection.height / 2) + padY).clamp(0, imgH);

    final cropW = (right - left).toInt();
    final cropH = (bottom - top).toInt();

    final cropCanvas = html.CanvasElement(width: cropW, height: cropH);
    final cropCtx = cropCanvas.context2D;

    cropCtx.drawImageScaledFromSource(
      img,
      left.toDouble(), top.toDouble(),
      cropW.toDouble(), cropH.toDouble(),
      0, 0,
      cropW.toDouble(), cropH.toDouble(),
    );

    html.Url.revokeObjectUrl(blobUrl);

    // Preprocessing: grayscale + contrast + threshold
    final imageData = cropCtx.getImageData(0, 0, cropW, cropH);
    final data = imageData.data;
    for (int i = 0; i < data.length; i += 4) {
      final r = data[i]; final g = data[i + 1]; final b = data[i + 2];
      int gray = (0.299 * r + 0.587 * g + 0.114 * b).round();
      gray = ((gray - 128) * 1.5 + 128).round().clamp(0, 255);
      final v = gray > 140 ? 255 : 0;
      data[i] = v; data[i + 1] = v; data[i + 2] = v;
    }
    cropCtx.putImageData(imageData, 0, 0);

    // Resize to optimal OCR dimensions
    const outputW = 400;
    const outputH = 150;
    final outputCanvas = html.CanvasElement(width: outputW, height: outputH);
    final outputCtx = outputCanvas.context2D;
    outputCtx.drawImageScaledFromSource(cropCanvas,
        0, 0, cropW.toDouble(), cropH.toDouble(),
        0, 0, outputW.toDouble(), outputH.toDouble());

    completer.complete(outputCanvas.toDataUrl('image/png'));
  });

  img.onError.listen((_) {
    html.Url.revokeObjectUrl(blobUrl);
    final reader = html.FileReader();
    reader.readAsDataUrl(html.Blob([imageBytes]));
    reader.onLoad.listen((_) {
      final result = reader.result;
      completer.complete(result is String ? result : result.toString());
    });
    reader.onError.listen((_) => completer.completeError('Image load failed'));
  });

  img.src = blobUrl;
  return completer.future;
}

// ─────────────────────────────────────────────────────────────────
class CameraScannerScreen extends StatefulWidget {
  const CameraScannerScreen({super.key});
  @override
  State<CameraScannerScreen> createState() => _WebScannerState();
}

class _WebScannerState extends State<CameraScannerScreen> {
  final _db       = FirestoreService();
  final _roboflow = RoboflowService();
  final _lpr      = PlateRecognizerService();

  bool    _processing  = false;
  String  _status      = '';
  String? _error;

  // Cache for fuzzy matching
  Set<String> _dbPlates = {};
  List<String> _candidates = [];
  bool _isScanning = false;
  bool _apiBusy = false; // For Plate Recognizer API feedback

  // Live camera
  html.VideoElement? _videoElement;
  html.MediaStream?  _mediaStream;
  bool    _cameraReady  = false;
  bool    _cameraFailed = false;
  String? _cameraError;
  final String  _viewId = 'web-camera-${DateTime.now().millisecondsSinceEpoch}';

  // Tesseract ready state
  bool _ocrReady = false;
  StreamSubscription? _ocrReadySub;
  // Active Tesseract listener subscription
  StreamSubscription? _tesseractSub;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _listenForOcrReady();
    _loadDbPlates();
  }

  Future<void> _loadDbPlates() async {
    final plates = await _db.getAllUniquePlates();
    if (mounted) setState(() => _dbPlates = plates);
  }

  @override
  void dispose() {
    _stopCamera();
    _ocrReadySub?.cancel();
    _tesseractSub?.cancel();
    super.dispose();
  }

  // ── Listen for Tesseract ready signal ─────────────────────────
  void _listenForOcrReady() {
    _ocrReadySub = html.window.onMessage.listen((event) {
      final data = event.data;
      if (data is Map && data['type'] == 'tesseract_ready') {
        if (mounted) setState(() => _ocrReady = true);
      }
    });
  }

  // ── Live camera via getUserMedia ──────────────────────────────
  Future<void> _initCamera() async {
    try {
      _videoElement = html.VideoElement()
        ..autoplay = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';

      // Prefer rear camera (environment)
      _mediaStream = await html.window.navigator.mediaDevices!.getUserMedia({
        'video': {
          'facingMode': {'ideal': 'environment'},
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        },
        'audio': false,
      });

      _videoElement!.srcObject = _mediaStream;
      await _videoElement!.play();

      // Register as platform view
      html.document.getElementById(_viewId)?.remove();
      _videoElement!.id = _viewId;

      // ignore: undefined_prefixed_name
      ui_web.platformViewRegistry.registerViewFactory(
        _viewId,
        (int id) => _videoElement!,
      );

      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) setState(() {
        _cameraFailed = true;
        _cameraError = 'Camera error: $e';
      });
    }
  }

  void _stopCamera() {
    _mediaStream?.getTracks().forEach((t) => t.stop());
    _mediaStream = null;
    _videoElement = null;
  }

  // ── Capture snapshot from video ───────────────────────────────
  Future<Uint8List?> _captureFrame() async {
    if (_videoElement == null) return null;
    try {
      final w = _videoElement!.videoWidth;
      final h = _videoElement!.videoHeight;
      if (w == 0 || h == 0) return null;

      final canvas = html.CanvasElement(width: w, height: h);
      canvas.context2D.drawImage(_videoElement!, 0, 0);
      final dataUrl = canvas.toDataUrl('image/jpeg', 0.92);
      final comma = dataUrl.indexOf(',');
      if (comma < 0) return null;
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (e) {
      return null;
    }
  }

  // ── Capture & Scan ────────────────────────────────────────────
  Future<void> _captureAndScan() async {
    if (_processing) return;
    setState(() { _processing = true; _error = null; _status = 'Capturing...'; });

    try {
      final bytes = await _captureFrame();
      if (bytes == null) {
        setState(() { _processing = false; _error = 'Failed to capture frame'; });
        return;
      }

      String? plate;

      // Step 1: Try Roboflow detection → crop
      setState(() => _status = 'AI locating plate...');
      final detections = await _roboflow.detectPlates(bytes);
      final best = _roboflow.getBestDetection(detections);
      
      Uint8List targetBytes = bytes;
      if (best != null) {
        // Zoom in on plate for better OCR
        final (l, t, r, b) = best.boundingBox;
        final padW = (best.width * 0.15).toInt();
        final padH = (best.height * 0.15).toInt();
        final cropped = await _cropImage(bytes, l - padW, t - padH, r + padW, b + padH);
        if (cropped != null) targetBytes = cropped;
      }

      final dataUrl = _bytesToDataUrl(targetBytes);

      // Step 2: Tesseract on crop
      setState(() { _status = 'Step 2: AI reading plate...'; });
      plate = await _runTesseractOCR(dataUrl);
      
      // Step 3: Fallback: If Tesseract fails or is inaccurate, use Plate Recognizer API
      if (plate == null || plate.isEmpty) {
        setState(() { 
          _status = 'Step 2: AI Enhancing (Fallback)...'; 
          _apiBusy = true;
        });
        // Send the zoomed crop to the API for max accuracy
        final apiResult = await _lpr.readPlate(targetBytes);
        plate = apiResult?.plate.toUpperCase();
      }

      if (!mounted) return;
      setState(() { _processing = false; _status = ''; _apiBusy = false; });

      if (plate != null && plate.isNotEmpty) {
        // Fuzzy match against database
        final fuzzy = _fuzzySearchDb(plate, _dbPlates);
        if (fuzzy != null) plate = fuzzy;
        
        await _autoSearch(plate);
      } else {
        setState(() => _error = 'No plate recognized even with AI.');
      }
    } catch (e) {
      if (mounted) setState(() { _processing = false; _error = 'Scan failed: $e'; _apiBusy = false; });
    }
  }

  /// Helper to capture current video frame as bytes for the API fallback
  Future<Uint8List?> _captureCurrentFrameAsBytes() async {
    if (_videoElement == null) return null;
    final canvas = html.CanvasElement(
      width: _videoElement!.videoWidth, 
      height: _videoElement!.videoHeight
    );
    canvas.context2D.drawImage(_videoElement!, 0, 0);
    final blob = await canvas.toBlob('image/jpeg');
    final reader = html.FileReader();
    reader.readAsArrayBuffer(blob);
    await reader.onLoad.first;
    return reader.result as Uint8List?;
  }

  /// Convert raw image bytes to a data:image URL for Tesseract
  String _bytesToDataUrl(Uint8List bytes) {
    final b64 = base64Encode(bytes);
    return 'data:image/jpeg;base64,$b64';
  }

  /// Helper to crop image bytes via Canvas on Web
  Future<Uint8List?> _cropImage(Uint8List bytes, int l, int t, int r, int b) async {
    try {
      final img = html.ImageElement();
      img.src = _bytesToDataUrl(bytes);
      await img.onLoad.first;

      final srcX = l.clamp(0, img.width!);
      final srcY = t.clamp(0, img.height!);
      final srcW = (r - l).clamp(1, img.width! - srcX);
      final srcH = (b - t).clamp(1, img.height! - srcY);

      final canvas = html.CanvasElement(width: srcW, height: srcH);
      canvas.context2D.drawImageScaledFromSource(
        img, srcX, srcY, srcW, srcH, 0, 0, srcW, srcH
      );

      final blob = await canvas.toBlob('image/jpeg', 0.9);
      final reader = html.FileReader();
      reader.readAsArrayBuffer(blob);
      await reader.onLoad.first;
      return reader.result as Uint8List?;
    } catch (e) {
      return null;
    }
  }

  // ── Run Tesseract.js OCR via postMessage ──────────────────────
  Future<String?> _runTesseractOCR(String dataUrl) async {
    final completer = Completer<String?>();
    final requestId = 'ocr_${DateTime.now().millisecondsSinceEpoch}';

    // Cancel any previous listener to prevent leaks
    _tesseractSub?.cancel();

    final timeout = Timer(const Duration(seconds: 20), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    // One-shot listener for this specific request
    _tesseractSub = html.window.onMessage.listen((event) {
      final data = event.data;
      final allElements = <({String text, double x, double y, double h})>[];
      final allTextRaw = <String>[];
      
      if (data is Map && data['type'] == 'tesseract_result' && data['requestId'] == requestId) {
        timeout.cancel();
        _tesseractSub?.cancel();
        _tesseractSub = null;
        final words = data['words'] as List? ?? [];
        for (final w in words) {
          if (w is Map) {
            final text = (w['text'] as String? ?? '').replaceAll(RegExp(r'[^A-Z0-9]'), '').toUpperCase();
            if (text.isEmpty) continue;
            
            final bbox = w['bbox'] as Map?;
            if (bbox != null) {
              final x0 = (bbox['x0'] ?? 0).toDouble();
              final y0 = (bbox['y0'] ?? 0).toDouble();
              final x1 = (bbox['x1'] ?? 0).toDouble();
              final y1 = (bbox['y1'] ?? 0).toDouble();
              allElements.add((text: text, x: x0, y: y0, h: y1 - y0));
            }
            allTextRaw.add(text);
          }
        }

        if (allTextRaw.isEmpty) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }

        if (mounted) setState(() => _candidates = allTextRaw.take(3).toList());

        // Try to match plate from OCR words with positional awareness
        final result = _tryTokens(allElements, _dbPlates);
        if (!completer.isCompleted) completer.complete(result);
      }
    });

    // Send scan request to Tesseract bridge
    html.window.postMessage({
      'type': 'tesseract_scan',
      'imageUrl': dataUrl,
      'requestId': requestId,
    }, '*');

    return completer.future;
  }

  // ── Auto-search: DB lookup → show result or fallback ──────────
  Future<void> _autoSearch(String plate) async {
    try {
      const swaps = {
        'B':'8','8':'B','O':'0','0':'O','I':'1','1':'I',
        'S':'5','5':'S','Z':'2','2':'Z','G':'6','6':'G',
      };
      final variants = <String>{plate};
      for (int i = 0; i < plate.length; i++) {
        final alt = swaps[plate[i]];
        if (alt != null) {
          variants.add(plate.substring(0, i) + alt + plate.substring(i + 1));
        }
      }

      final results = await Future.wait(
          variants.where(_isValid).map((v) => _db.searchVehicle(v)));

      final seen = <String>{}; final merged = <VehicleModel>[];
      for (final list in results) {
        for (final v in list) {
          if (seen.add(v.plateNumber)) merged.add(v);
        }
      }

      if (!mounted) return;
      setState(() { _processing = false; _status = ''; });

      // Show result popup for both "Found" (merged) and "Not Found" ([])
      _showResult(merged, plate);
    } catch (e) {
      if (mounted) setState(() { _processing = false; _error = 'Search failed: $e'; });
    }
  }

  // ── Confirm / edit detected plate ─────────────────────────────
  Future<void> _confirmDialog(String detected) async {
    final ctrl = TextEditingController(text: detected);

    final confirmed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: Colors.red[50], borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.document_scanner_rounded,
                color: Color(0xFFFF0000), size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Confirm Plate',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              detected.isEmpty
                  ? 'No plate detected. Type it manually:'
                  : 'Detected plate number.\nCorrect it if needed:',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 7,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 6),
              decoration: InputDecoration(
                counterText: '',
                hintText: 'e.g. NHM4030',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFFF0000), width: 2),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, ctrl.text.trim().toUpperCase()),
            icon: const Icon(Icons.search_rounded, color: Colors.white, size: 18),
            label: const Text('Search',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == null || confirmed.isEmpty || !mounted) return;

    setState(() { _processing = true; _status = 'Searching database...'; });

    try {
      const swaps = {
        'B':'8','8':'B','O':'0','0':'O','I':'1','1':'I',
        'S':'5','5':'S','Z':'2','2':'Z','G':'6','6':'G',
      };
      final variants = <String>{confirmed};
      for (int i = 0; i < confirmed.length; i++) {
        final alt = swaps[confirmed[i]];
        if (alt != null) {
          variants.add(confirmed.substring(0, i) + alt + confirmed.substring(i + 1));
        }
      }

      final results = await Future.wait(
          variants.where(_isValid).map((v) => _db.searchVehicle(v)));

      final seen = <String>{}; final merged = <VehicleModel>[];
      for (final list in results) {
        for (final v in list) {
          if (seen.add(v.plateNumber)) merged.add(v);
        }
      }

      if (!mounted) return;
      setState(() { _processing = false; _status = ''; });
      _showResult(merged, confirmed);
    } catch (e) {
      setState(() { _processing = false; _error = 'Search failed: $e'; });
    }
  }

  // ── Result popup ──────────────────────────────────────────────
  void _showResult(List<VehicleModel> vehicles, String plate) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: vehicles.isNotEmpty ? 0.88 : 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, __) => VehicleResultPopup(
          vehicles: vehicles,
          searchedPlate: plate,
          searchMode: SearchMode.camera,
          onScanAnother: () {
            Navigator.pop(context);
          },
          onTypeSearchAnother: () => Navigator.pop(context),
          onScanAgain: () {
            Navigator.pop(context);
          },
          onBackToDashboard: () => Navigator.pop(context),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // ── Live camera preview ────────────────────────────────
        if (_cameraReady)
          Positioned.fill(
            child: HtmlElementView(viewType: _viewId),
          )
        else if (_cameraFailed)
          Center(child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.videocam_off_rounded, color: Colors.grey, size: 56),
              const SizedBox(height: 16),
              Text(_cameraError ?? 'Camera unavailable',
                  style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ]),
          ))
        else
          const Center(child: CircularProgressIndicator(color: Color(0xFFFF0000))),

        // ── Dark overlay with frame cutout ──────────────────────
        if (_cameraReady)
          Positioned.fill(child: IgnorePointer(
            child: CustomPaint(painter: _OverlayPainter()),
          )),

        // ── Scan frame brackets ─────────────────────────────────
        if (_cameraReady)
          const Center(child: SizedBox(
            width: 300, height: 100,
            child: CustomPaint(painter: _BracketPainter(color: Colors.white)),
          )),

        // ── Top bar ─────────────────────────────────────────────
        SafeArea(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Scan Plate',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            // OCR status badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _ocrReady ? Colors.green.withOpacity(0.5) : Colors.orange.withOpacity(0.5)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 6, height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: _ocrReady ? Colors.green : Colors.orange)),
                const SizedBox(width: 5),
                Text(_ocrReady ? 'OCR Ready' : 'Loading OCR',
                    style: TextStyle(
                        color: _ocrReady ? Colors.green : Colors.orange,
                        fontSize: 10, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        )),

        // ── Status + error ──────────────────────────────────────
        if (_processing)
          Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF0000))),
                if (_status.isNotEmpty) ...[
                  Text(_status, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  if (_apiBusy) ...[
                    const SizedBox(height: 12),
                    CircularProgressIndicator(strokeWidth: 2.5, color: Colors.blue[300]),
                  ],
                ],
            ]),
          )),

        if (_error != null && !_processing)
          Positioned(
            top: 100, left: 24, right: 24,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red[900]!.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!,
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
                GestureDetector(
                  onTap: () => setState(() => _error = null),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                ),
              ]),
            ),
          ),

        // ── Format pills ────────────────────────────────────────
        if (_cameraReady && !_processing)
          Positioned(
            bottom: 160, left: 0, right: 0,
            child: Column(
              children: [
                if (_candidates.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('Reading: ${_candidates.join(", ")}',
                        style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                  _Pill(label: 'PLATE', example: 'NHM4030'),
                  SizedBox(width: 8),
                  _Pill(label: 'CS', example: 'RB0827'),
                ]),
              ],
            ),
          ),

        // ── Bottom: Capture button ──────────────────────────────
        if (_cameraReady)
          Positioned(
            bottom: 44, left: 0, right: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                _processing ? _status : 'Point camera at plate and tap to scan',
                style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: _processing ? null : _captureAndScan,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _processing ? Colors.grey[700] : const Color(0xFFFF0000),
                    border: Border.all(color: Colors.white, width: 3.5),
                    boxShadow: !_processing ? [
                      BoxShadow(color: const Color(0xFFFF0000).withOpacity(0.45),
                          blurRadius: 20, spreadRadius: 3),
                    ] : [],
                  ),
                  child: _processing
                      ? const Padding(padding: EdgeInsets.all(22),
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 30),
                ),
              ),
              const SizedBox(height: 8),
              Text('Capture & Scan',
                  style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 10)),
            ]),
          ),
      ]),
    );
  }
}

// ── Painters ──────────────────────────────────────────────────────
class _OverlayPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(
            (size.width - 300) / 2, (size.height - 100) / 2,
            300, 100),
          const Radius.circular(6)))
        ..fillType = PathFillType.evenOdd,
      Paint()..color = Colors.black.withOpacity(0.62)..style = PaintingStyle.fill,
    );
  }
  @override bool shouldRepaint(_) => false;
}

class _BracketPainter extends CustomPainter {
  final Color color;
  const _BracketPainter({required this.color});
  @override void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = 3.5
      ..strokeCap = StrokeCap.square..style = PaintingStyle.stroke;
    const len = 22.0;
    final w = size.width; final h = size.height;
    canvas.drawLine(Offset(0, len), Offset.zero, p);
    canvas.drawLine(Offset.zero, Offset(len, 0), p);
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), p);
    canvas.drawLine(Offset(w, 0), Offset(w, len), p);
    canvas.drawLine(Offset(0, h - len), Offset(0, h), p);
    canvas.drawLine(Offset(0, h), Offset(len, h), p);
    canvas.drawLine(Offset(w - len, h), Offset(w, h), p);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), p);

    final midPaint = Paint()
      ..color = color.withOpacity(0.5)..strokeWidth = 1.5..style = PaintingStyle.stroke;
    const dashWidth = 8.0; const dashSpace = 6.0;
    double startX = 30.0;
    final midY = h / 2;
    while (startX < w - 30) {
      final endX = (startX + dashWidth).clamp(0.0, w - 30);
      canvas.drawLine(Offset(startX, midY), Offset(endX, midY), midPaint);
      startX += dashWidth + dashSpace;
    }
  }
  @override bool shouldRepaint(covariant _BracketPainter o) => o.color != color;
}

class _Pill extends StatelessWidget {
  final String label, example;
  const _Pill({required this.label, required this.example});
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
        color: Colors.black54, borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            color: const Color(0xFFFF0000), borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: const TextStyle(
            color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
      ),
      const SizedBox(width: 6),
      Text(example, style: const TextStyle(
          color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1)),
    ]),
  );
}