import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'package:image/image.dart' as img_lib;
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../services/plate_recognizer_service.dart';
import '../services/firestore_service.dart';
import '../services/roboflow_service.dart';
import '../models/vehicle_model.dart';
import '../widgets/vehicle_result_popup.dart';

// ── Frame dimensions ──────────────────────────────────────────────
const double _kFrameW = 300.0;
const double _kFrameH = 100.0;
// Vertical offset for the scan frame (negative moves the frame upward).
// Set to 0 to keep the frame centered.
const double _kFrameYOffsetFraction = 0.0;

// Require this fraction of the OCR element to be within the scan frame
// in order for it to be considered. This prevents partial detections from
// being used during auto-scan.
const double _kMinFrameOverlapFraction = 0.75;

// ── Auto-scan tuning ──────────────────────────────────────────────
const int      _kStreak   = 1;                           // instant — show result on first valid read
const Duration _kCooldown = Duration(milliseconds: 220); // gap between OCR calls

// ── Philippine plate regexes ──────────────────────────────────────
final _rxPlate = RegExp(r'^[A-Z]{3}[0-9]{4}$');          // NHM4030
final _rxOld   = RegExp(r'^[A-Z]{3}[0-9]{3}$');          // ABC123
final _rxCS    = RegExp(r'^[A-Z]{2}[0-9]{3,4}[A-Z]?$');  // RB0827 / RB0827A / HZ903B (conduction sticker)

bool _isValid(String s) =>
    _rxPlate.hasMatch(s) || _rxOld.hasMatch(s) || _rxCS.hasMatch(s);

/// Represents an OCR element with its text and position
class OcrElement {
  final String text;
  final double x;       // Center X
  final double y;       // Center Y
  final double width;
  final double height;
  final double left;    // Left edge
  final double top;     // Top edge
  final double right;   // Right edge
  final double bottom;  // Bottom edge

  OcrElement({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Check if this element is a single letter
  bool get isSingleLetter => text.length == 1 && RegExp(r'^[A-Z]$').hasMatch(text);

  /// Check if this element contains only digits
  bool get isDigitsOnly => RegExp(r'^[0-9]+$').hasMatch(text);

  /// Check if this element is likely part of a conduction sticker number
  bool get isLikelyPlateNumber => RegExp(r'^[A-Z0-9]+$').hasMatch(text);

  @override
  String toString() => 'OcrElement(text: $text, x: ${x.toStringAsFixed(1)}, y: ${y.toStringAsFixed(1)})';
}

// ─────────────────────────────────────────────────────────────────
class CameraScannerScreen extends StatefulWidget {
  const CameraScannerScreen({super.key});
  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen>
    with WidgetsBindingObserver {

  CameraController? _ctrl;
  bool    _cameraReady = false;
  String? _cameraError;

  final _ocr = TextRecognizer();
  final _db       = FirestoreService();
  final _roboflow = RoboflowService();
  final _lpr      = PlateRecognizerService();

  // Gate — prevents overlapping OCR calls
  bool     _processing = false;


  // Streak
  String? _streakPlate;
  int     _streakCount = 0;

  // Fast-search support: if a plate is already known to be in the DB,
  // show results immediately without waiting for further streaks.
  String? _pendingSearchPlate;
  Future<void>? _pendingSearch;

  // Cache recent DB search results so repeating a plate returns instantly.
  final Map<String, List<VehicleModel>> _dbSearchCache = {};
  static const _kCacheTTL = Duration(minutes: 5);

  // Cache for all unique plates in Firestore to support fuzzy matching
  Set<String> _dbPlates = {};
  
  // UI State
  String  _hint        = 'Align plate inside the frame';
  String? _reading;            // plate currently building streak
  bool    _isScanning  = false; // OCR in progress
  String? _noRecordMsg;         // inline "no record" message for auto-scan
  List<String> _candidates = []; // HUD: candidates currently being seen
  bool    _apiBusy     = false; // For Plate Recognizer API feedback
  bool    _manualBusy  = false; // True during manual scan
  bool    _resultShown = false; // True while bottom sheet is open
  bool    _isDisposed  = false; // Widget life cycle gate
  Timer?  _autoTimer;           // For auto-scan frames
  DateTime _lastFrame  = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _loadDbPlates();
  }

  Future<void> _loadDbPlates() async {
    final plates = await _db.getAllUniquePlates();
    if (mounted) {
      setState(() => _dbPlates = plates);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _autoTimer = null;


    // Ensure the stream is fully stopped before disposing the controller.
    // Disposing a CameraController while it still has active listeners can
    // trigger `_dependents.isEmpty` assertion failures in the plugin.
    if (_ctrl != null) {
      final stopFuture = _ctrl!.value.isStreamingImages
          ? _ctrl!.stopImageStream().catchError((_) {})
          : Future.value();
      stopFuture.whenComplete(() => _ctrl?.dispose());
    }

    _ocr.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (_isDisposed) return;
    if (s == AppLifecycleState.inactive) unawaited(_stopStream());
    if (s == AppLifecycleState.resumed && _cameraReady) _startStream();
  }

  // ── Camera ────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) { setState(() => _cameraError = 'No camera found.'); return; }
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // Use high resolution for better OCR accuracy on plates at moderate distance.
      // Combined with streak=2 and frame cooldown, this keeps scanning responsive
      // while providing significantly better text detail.
      _ctrl = CameraController(cam, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      await _ctrl!.initialize();
      await _ctrl!.setFocusMode(FocusMode.auto);
      await _ctrl!.setFlashMode(FlashMode.off);
      await _ctrl!.setExposureMode(ExposureMode.auto);
      if (mounted) {
        setState(() => _cameraReady = true);
        _startStream();
      }
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Camera error: $e');
    }
  }

  // ── Auto-scan: image stream ───────────────────────────────────
  // Camera delivers raw NV21 frames at ~30fps.
  // We pass the FULL frame to ML Kit (no byte slicing — that was
  // the bug before). The height-filter in _parsePlate ignores all
  // small surrounding text, so we don't need to crop the image.
  // A cooldown gate (controlled by _kCooldown) prevents overlapping OCR calls.
  // Result: ~200-300ms per scan vs ~700ms+ for takePicture().
  void _startStream() {
    if (_isDisposed || _ctrl == null || _ctrl!.value.isStreamingImages) return;
    _ctrl!.startImageStream(_onFrame).catchError((_) {});
  }

  Future<void> _stopStream() async {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (_ctrl == null || !_ctrl!.value.isStreamingImages) return;

    try {
      await _ctrl!.stopImageStream();
    } catch (_) {
      // ignore
    }
  }

  void _onFrame(CameraImage image) {
    if (_isDisposed || _processing || _resultShown || _manualBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < _kCooldown) return;
    _lastFrame  = now;
    _processing = true;
    if (mounted) setState(() => _isScanning = true);
    _processFrame(image).whenComplete(() {
      _processing = false;
      if (mounted) setState(() => _isScanning = false);
    });
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_isDisposed) return;
    try {
      // Build InputImage from raw NV21 — full frame, no slicing.
      // TODO: If still slow, consider cropping/resizing to the scan box only.
      final inputImage = _nv21ToInputImage(image);
      if (inputImage == null) return;

      // Calculate the approximate scan frame region in image coordinates.
      // This lets us ignore OCR results that come from outside the box.
      final frameRect = _getFrameRectForImage(image);

      // For speed, skip Roboflow (network call) and rely on local OCR + frame filtering.
      // This keeps auto-scan responsive (few seconds) and avoids per-frame HTTP overhead.
      if (!_isScanning && mounted) setState(() => _isScanning = true);

      final ocr = await _ocr.processImage(inputImage);
      if (!mounted || _resultShown) return;

      final plate = _parsePlate(ocr, frameRect);
      
      // UI HUD: Collect candidates for feedback
      final candidates = <String>[];
      for (final block in ocr.blocks) {
        for (final line in block.lines) {
          final text = line.text.replaceAll(RegExp(r'[^A-Z0-9]'), '').toUpperCase();
          if (text.length >= 5) candidates.add(text);
        }
      }
      if (mounted) setState(() => _candidates = candidates.take(3).toList());

      if (plate == null) {
        if (_streakCount > 0) {
          _streakPlate = null; _streakCount = 0;
          if (mounted) setState(() {
            _reading = null;
            _hint    = 'Align plate inside the frame';
          });
        }
        return;
      }
      if (!mounted || _resultShown) return;

      // 1. Check if exactly in DB cache or DB Search Cache
      final inDb = _dbPlates.contains(plate) || _dbPlates.contains(_fuzzySearchDb(plate) ?? '');
      final cached = _dbSearchCache[plate];

      if (inDb || (cached != null && cached.isNotEmpty)) {
        if (!mounted || _resultShown) return;
        // Even if not in search cache yet, we know it's in DB, so start search and it will pop.
        if (cached != null && cached.isNotEmpty) {
          if (mounted) setState(() => _resultShown = true);
          _showResult(cached, plate);
          return;
        } else {
          // It's in _dbPlates, so we are confident. Trigger immediate search.
          _maybeStartSearch(plate);
          if (mounted) setState(() { _reading = plate; _hint = 'Match found!'; });
          // We don't return here because _maybeStartSearch will handle the popup, 
          // but we skip the "streak building" UI below.
        }
      }


      // Build streak
      if (plate == _streakPlate) {
        _streakCount++;
      } else {
        _streakPlate = plate; _streakCount = 1;
        if (mounted && _noRecordMsg != null) setState(() => _noRecordMsg = null);
      }

      if (mounted) setState(() {
        _reading = plate;
        _hint    = inDb ? 'Match found!' : 'Reading ($_streakCount/$_kStreak)...';
      });

      // Kick off a fast DB lookup; if it finds a matching vehicle we show it immediately.
      // This happens in parallel with the streak build so we can return results
      // as soon as the DB responds.
      _maybeStartSearch(plate);

      if (_streakCount < _kStreak) return;

      // ── Confirmed — search DB (fallback if the fast path hasn't already shown results)
      _streakPlate = null; _streakCount = 0;
      if (mounted) setState(() { _reading = null; _hint = 'Searching...'; });

      final results = await _dbSearch(plate);
      if (!mounted || _resultShown) return;

      // ── Show Result ──────────────────────────────────────────────
      // Whether it's in the DB or not, stop the scanner and show the result sheet.
      // The VehicleResultPopup automatically handles the "Not Found" state beautifully.
      if (mounted) setState(() => _resultShown = true);
      _showResult(results, plate);
    } catch (_) { /* silent frame error */ }
  }

  /// Attempts a quick DB lookup for [plate] and shows the result immediately
  /// if the plate exists.
  void _maybeStartSearch(String plate) {
    // If we already have an in-progress or completed query for this plate, skip.
    if (_pendingSearchPlate == plate && _pendingSearch != null) return;

    _pendingSearchPlate = plate;
    _pendingSearch = () async {
      final results = await _dbSearch(plate);
      _pendingSearch = null;
      if (!mounted || _resultShown) return;
      
      if (results.isNotEmpty) {
        if (mounted) setState(() => _resultShown = true);
        _showResult(results, plate);
      }
    }();
  }

  // ── Convert CameraImage (NV21) → InputImage for ML Kit ────────
  // NV21 format = Y plane + interleaved VU plane.
  // Must concatenate ALL planes into one buffer for ML Kit to decode
  // the image correctly. Passing only plane[0] gives ML Kit a
  // grayscale-only buffer which produces poor OCR results.
  InputImage? _nv21ToInputImage(CameraImage image) {
    try {
      // Concatenate all plane bytes into a single NV21 buffer
      int totalBytes = 0;
      for (final p in image.planes) totalBytes += p.bytes.length;
      final nv21 = Uint8List(totalBytes);
      int offset = 0;
      for (final p in image.planes) {
        nv21.setRange(offset, offset + p.bytes.length, p.bytes);
        offset += p.bytes.length;
      }

      return InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size:        Size(image.width.toDouble(), image.height.toDouble()),
          rotation:    InputImageRotation.rotation90deg,
          format:      InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (_) { return null; }
  }

  /// Returns the approximate crop rectangle of the scan box in the raw image
  /// coordinate space.
  ///
  /// This allows us to ignore OCR results detected outside the visible
  /// scan frame, which improves accuracy when the camera sees text outside
  /// the target box.
  Rect? _getFrameRectForImage(CameraImage image) {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return null;

    final prev = _ctrl!.value.previewSize;
    if (prev == null) return null;

    // The preview's width/height are swapped relative to the raw image.
    // This matches the transformation used in _cropToFrame.
    final prevW = prev.height;
    final prevH = prev.width;

    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    final sx = imgW / prevW;
    final sy = imgH / prevH;

    const padX = 56.0;
    const padY = 20.0;

    final fl = ((prevW - _kFrameW) / 2 - padX) * sx;
    final ft = (((prevH - _kFrameH) / 2 - padY) + (prevH / 2) * _kFrameYOffsetFraction) * sy;
    final fw = (_kFrameW + padX * 2) * sx;
    final fh = (_kFrameH + padY * 2) * sy;

    final left = fl.clamp(0.0, imgW - 1);
    final top = ft.clamp(0.0, imgH - 1);
    final right = (left + fw).clamp(0.0, imgW);
    final bottom = (top + fh).clamp(0.0, imgH);

    return Rect.fromLTRB(left, top, right, bottom);
  }

  // ── Manual capture ─────────────────────────────────────────────
  /// Capture current frame and run full high-accuracy analysis
  Future<void> _manualCapture() async {
    if (!mounted || _manualBusy || _resultShown) return;
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;

    // Pause auto-scan while capturing
    await _stopStream();
    if (!mounted) return;
    
    setState(() { 
      _manualBusy = true; 
      _reading = null; 
      _noRecordMsg = null; 
      _hint = 'Capturing...'; 
    });

    String? filePath;
    try {
      final img = await _ctrl!.takePicture();
      filePath = img.path;
      final rawBytes = await File(img.path).readAsBytes();

      if (mounted) setState(() => _hint = 'AI optimizing image...');
      
      // 1. Offload EXIF rotation and resizing to an Isolate to prevent UI hang
      // and ensure image fits within Plate Recognizer's 3MB API limits.
      // 1. EXIF rotation + resize (inline, no Isolate — avoids serialization crash)
      Uint8List targetBytes;
      try {
        final decoded = img_lib.decodeImage(rawBytes);
        if (decoded != null) {
          var baked = img_lib.bakeOrientation(decoded);
          if (baked.width > 1920 || baked.height > 1920) {
            baked = img_lib.copyResize(baked, 
              width: baked.width > baked.height ? 1920 : null, 
              height: baked.height >= baked.width ? 1920 : null);
          }
          targetBytes = Uint8List.fromList(img_lib.encodeJpg(baked, quality: 85));
        } else {
          targetBytes = rawBytes;
        }
      } catch (_) {
        targetBytes = rawBytes; // fallback: send raw bytes
      }

      if (mounted) setState(() => _hint = 'AI locating plate...');
      
      // 2. Detection via Roboflow
      final detections = await _roboflow.detectPlates(targetBytes);
      final best = _roboflow.getBestDetection(detections);
      
      if (best != null) {
        if (mounted) setState(() => _hint = 'AI scanning zoomed crop...');
        // 3. Crop to plate with 15% padding (extract primitives to avoid Isolate issues)
        try {
          final decoded = img_lib.decodeJpg(targetBytes);
          if (decoded != null) {
            final (l, t, r, b) = best.boundingBox;
            final padW = (best.width * 0.15).toInt();
            final padH = (best.height * 0.15).toInt();
            
            final cl = (l - padW).clamp(0, decoded.width - 1);
            final ct = (t - padH).clamp(0, decoded.height - 1);
            final cw = (r - l + padW * 2).clamp(1, decoded.width - cl);
            final ch = (b - t + padH * 2).clamp(1, decoded.height - ct);
            
            final crop = img_lib.copyCrop(decoded, x: cl, y: ct, width: cw, height: ch);
            targetBytes = Uint8List.fromList(img_lib.encodeJpg(crop, quality: 95));
          }
        } catch (_) { /* keep targetBytes as-is */ }
      } else {
        if (mounted) setState(() => _hint = 'AI scanning full image...');
      }

      // 4. Use Plate Recognizer API for maximum accuracy
      final result = await _lpr.readPlate(targetBytes);
      
      try { File(img.path).deleteSync(); } catch (_) {}
      filePath = null;

      if (result == null || result.plate.isEmpty) {
        if (mounted) setState(() {
          _manualBusy = false;
          _hint = 'Align plate inside the frame';
          _noRecordMsg = 'No plate recognized even with AI.';
        });
        _startStream();
        return;
      }

      var plate = result.plate.toUpperCase();
      
      // Fuzzy match against database
      final fuzzy = _fuzzySearchDb(plate);
      if (fuzzy != null) plate = fuzzy;

      if (mounted) setState(() {
        _reading = plate;
        _hint = 'Plate recognized!';
      });

      final results = await _dbSearch(plate);
      if (!mounted) return;
      
      setState(() => _resultShown = true);
      _showResult(results, plate);

    } catch (e) {
      try { if (filePath != null) File(filePath).deleteSync(); } catch (_) {}
      if (mounted) setState(() {
        _manualBusy = false;
        _hint = 'Scan failed: $e';
      });
      _startStream();
    }
  }

  // Crop image using Roboflow detection bounding box
  Future<String> _cropToRoboflowBox(String path, PlateDetection detection) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frm = await codec.getNextFrame();
    final img = frm.image;
    
    // Get bounding box (center-based to corner-based)
    final (left, top, right, bottom) = detection.boundingBox;
    
    // Add padding around the detection
    const padding = 10;
    final cl = (left - padding).clamp(0, img.width - 1);
    final ct = (top - padding).clamp(0, img.height - 1);
    final cw = (right - left + padding * 2).clamp(1, img.width - cl);
    final ch = (bottom - top + padding * 2).clamp(1, img.height - ct);
    
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      img,
      Rect.fromLTWH(cl.toDouble(), ct.toDouble(), cw.toDouble(), ch.toDouble()),
      Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      Paint(),
    );
    final cropped = await rec.endRecording().toImage(cw, ch);
    final pngBytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
    final out = '${path}_roboflow_crop.png';
    await File(out).writeAsBytes(pngBytes!.buffer.asUint8List());
    return out;
  }

  // ── Confirm dialog ────────────────────────────────────────────
  Future<void> _confirmAndSearch(String detected) async {
    // Stop stream completely before showing confirm
    await _stopStream();
    if (_isDisposed) return;
    if (!mounted) return;

    // Use a standard showDialog — simpler and avoids overlay lifecycle issues.
    final confirmed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConfirmDialog(detected: detected),
    );

    // If cancelled or not mounted, resume stream and return
    if (!mounted || confirmed == null || confirmed.isEmpty) {
      if (mounted) _startStream();
      return;
    }

    // Search and show result (found OR not found — always show popup)
    if (mounted) setState(() => _hint = 'Searching $confirmed...');
    final results = await _dbSearch(confirmed);
    if (!mounted) return;
    setState(() => _resultShown = true);
    _showResult(results, confirmed);
  }



  // ── File crop for manual capture ──────────────────────────────
  Future<String> _cropToFrame(String path) async {
    final bytes  = await File(path).readAsBytes();
    final codec  = await ui.instantiateImageCodec(bytes);
    final frm    = await codec.getNextFrame();
    final img    = frm.image;
    final imgW   = img.width.toDouble();
    final imgH   = img.height.toDouble();
    final prev   = _ctrl!.value.previewSize!;
    final prevW  = prev.height;
    final prevH  = prev.width;
    final sx     = imgW / prevW;
    final sy     = imgH / prevH;
    const padX = 56.0; const padY = 20.0;
    final fl = ((prevW - _kFrameW) / 2 - padX) * sx;
    final ft = (((prevH - _kFrameH) / 2 - padY) + (prevH / 2) * _kFrameYOffsetFraction) * sy;
    final fw = (_kFrameW + padX * 2) * sx;
    final fh = (_kFrameH + padY * 2) * sy;
    final cl = fl.clamp(0.0, imgW - 1).toInt();
    final ct = ft.clamp(0.0, imgH - 1).toInt();
    final cw = fw.clamp(1.0, imgW - cl).toInt();
    final ch = fh.clamp(1.0, imgH - ct).toInt();
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(img,
      Rect.fromLTWH(cl.toDouble(), ct.toDouble(), cw.toDouble(), ch.toDouble()),
      Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), Paint());
    final cropped  = await rec.endRecording().toImage(cw, ch);
    final pngBytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
    final out = '${path}_crop.png';
    await File(out).writeAsBytes(pngBytes!.buffer.asUint8List());
    return out;
  }

  // ── Plate parsing ─────────────────────────────────────────────
  String? _parsePlate(RecognizedText ocr, [Rect? frameRect]) {
    // First, try to detect conduction sticker pattern (vertical letters + horizontal numbers)
    final conductionResult = _parseConductionSticker(ocr, frameRect);
    if (conductionResult != null) {
      return conductionResult;
    }

    // Fall back to standard plate parsing
    final all = <({String text, double x, double y, double h})>[];
    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        for (final el in line.elements) {
          final pts = el.cornerPoints;
          if (pts.length < 2) continue;

          // Geometric position for sorting
          final minX = pts.map((p) => p.x.toDouble()).reduce(min);
          final minY = pts.map((p) => p.y.toDouble()).reduce(min);

          // Ignore any text outside the visible scan frame (usually at the top).
          if (frameRect != null) {
            final ys = pts.map((p) => p.y.toDouble());
            final xs = pts.map((p) => p.x.toDouble());
            final rect = Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
            final intersection = rect.intersect(frameRect);
            if (intersection.isEmpty) continue;
            final elementArea = rect.width * rect.height;
            if (elementArea <= 0) continue;
            final overlapRatio = (intersection.width * intersection.height) / elementArea;
            if (overlapRatio < _kMinFrameOverlapFraction) continue;
          }

          double hY1 = pts[0].y.toDouble(), hY2 = pts[0].y.toDouble();
          for (final pt in pts) {
            if (pt.y < hY1) hY1 = pt.y.toDouble();
            if (pt.y > hY2) hY2 = pt.y.toDouble();
          }
          final h = hY2 - hY1;

          final text = el.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
          if (text.isNotEmpty && h > 0) {
            all.add((text: text, x: minX, y: minY, h: h));
          }
        }
      }
    }

    if (all.isEmpty) return null;

    // Sort tokens by Y (top-to-bottom) then X (left-to-right) 
    // This is crucial for joining fragments like "DBA465" and "8" in the correct order.
    all.sort((a, b) {
      if ((a.y - b.y).abs() > (a.h * 0.5)) return a.y.compareTo(b.y);
      return a.x.compareTo(b.x);
    });

    final sortedHeights = all.map((e) => e.h).toList()..sort();
    final maxHeight = sortedHeights.last;
    final strictThresh = maxHeight * 0.85; 
    final mediumThresh = maxHeight * 0.70;
    
    // Maintain sorted order for tokens
    final eliteTokens = all.where((e) => e.h >= strictThresh).map((e) => e.text).toList();
    final mediumTokens = all.where((e) => e.h >= mediumThresh).map((e) => e.text).toList();
    final allTokens = all.map((e) => e.text).toList();

    // ── STEP 1: Search for 7-character plates ──────────────────────────
    final p7 = _tryTokensForLen(eliteTokens, 7) ?? _tryTokensForLen(mediumTokens, 7) ?? _tryTokensForLen(allTokens, 7);
    if (p7 != null) return p7;

    // ── STEP 2: Search for 6-character plates ──────────────────────────
    final p6 = _tryTokensForLen(eliteTokens, 6) ?? _tryTokensForLen(mediumTokens, 6) ?? _tryTokensForLen(allTokens, 6);
    if (p6 != null) return p6;

    return null;
  }

  // ── Conduction Sticker Detection ──────────────────────────────
  /// Detects Philippine conduction stickers with format:
  ///   A  1234
  ///   B
  /// Where letters (AB) are stacked vertically on the left,
  /// and numbers (1234) are horizontal on the right.
  String? _parseConductionSticker(RecognizedText ocr, [Rect? frameRect]) {
    final elements = <OcrElement>[];

    // Extract all OCR elements with their positions
    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        for (final el in line.elements) {
          final pts = el.cornerPoints;
          if (pts.length < 2) continue;

          // Apply frame filter if provided
          if (frameRect != null) {
            final xs = pts.map((p) => p.x.toDouble());
            final ys = pts.map((p) => p.y.toDouble());
            final rect = Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));

            final intersection = rect.intersect(frameRect);
            if (intersection.isEmpty) continue;

            final elementArea = rect.width * rect.height;
            if (elementArea <= 0) continue;
            final overlapRatio = (intersection.width * intersection.height) / elementArea;
            if (overlapRatio < _kMinFrameOverlapFraction) continue;
          }

          // Calculate center and bounds
          double minX = pts[0].x.toDouble(), maxX = pts[0].x.toDouble();
          double minY = pts[0].y.toDouble(), maxY = pts[0].y.toDouble();
          for (final pt in pts) {
            if (pt.x < minX) minX = pt.x.toDouble();
            if (pt.x > maxX) maxX = pt.x.toDouble();
            if (pt.y < minY) minY = pt.y.toDouble();
            if (pt.y > maxY) maxY = pt.y.toDouble();
          }

          final text = el.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
          if (text.isEmpty) continue;

          elements.add(OcrElement(
            text: text,
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2,
            width: maxX - minX,
            height: maxY - minY,
            left: minX,
            top: minY,
            right: maxX,
            bottom: maxY,
          ));
        }
      }
    }

    if (elements.isEmpty) return null;

    // Filter to only elements that look like plate text (large enough)
    final sortedByHeight = List<OcrElement>.from(elements)..sort((a, b) => b.height.compareTo(a.height));
    if (sortedByHeight.isEmpty) return null;

    final maxHeight = sortedByHeight.first.height;
    // Enforce a strict height filter to ignore small dealer/manufacturer sticker text.
    // The plate text (M-Q and the numbers) should be almost identical in height, 
    // making them the absolute largest text blocks.
    final minHeight = maxHeight * 0.75; 
    final largeElements = elements.where((e) => e.height >= minHeight).toList();

    if (largeElements.isEmpty) return null;

    // Strategy 1: Look for vertically stacked single letters + horizontal numbers
    final conductionResult = _detectVerticalLettersWithNumbers(largeElements);
    if (conductionResult != null) {
      return conductionResult;
    }

    // Strategy 2: Look for any combination that forms a valid conduction sticker
    return _detectConductionFromFragments(largeElements);
  }

  /// Detect vertically stacked letters (like A over B) with numbers to the right
  String? _detectVerticalLettersWithNumbers(List<OcrElement> elements) {
    // Find single-letter elements
    final singleLetters = elements.where((e) => e.isSingleLetter).toList();
    
    if (singleLetters.length < 2) return null;

    // Group letters by X-coordinate proximity (vertical columns)
    final letterColumns = <List<OcrElement>>[];
    final xTolerance = elements.isEmpty ? 20 : elements.map((e) => e.width).reduce((a, b) => a > b ? a : b) * 0.5;

    for (final letter in singleLetters) {
      bool added = false;
      for (final column in letterColumns) {
        final avgX = column.map((e) => e.x).reduce((a, b) => a + b) / column.length;
        if ((letter.x - avgX).abs() < xTolerance) {
          column.add(letter);
          added = true;
          break;
        }
      }
      if (!added) {
        letterColumns.add([letter]);
      }
    }

    // Find columns with 2+ vertically stacked letters
    for (final column in letterColumns) {
      if (column.length < 2) continue;

      // Sort by Y position (top to bottom)
      column.sort((a, b) => a.y.compareTo(b.y));

      // Take the first 2 letters (top and bottom)
      final topLetter = column[0];
      final bottomLetter = column[1];

      // Check they're actually stacked (different Y positions)
      final yGap = (bottomLetter.y - topLetter.y).abs();
      if (yGap < topLetter.height * 0.5) continue; // Too close, probably same line

      // Find number elements to the right of the letter column
      final avgLetterX = column.map((e) => e.x).reduce((a, b) => a + b) / column.length;
      final numberElements = elements.where((e) {
        if (!e.isDigitsOnly && e.text.length <= 4) return false;
        return e.left > avgLetterX + (e.width * 0.3); // To the right of letters
      }).toList();

      // Sort number elements by proximity to letters (left to right)
      numberElements.sort((a, b) => a.left.compareTo(b.left));

      // Try to build a conduction sticker number
      final letters = '${topLetter.text}${bottomLetter.text}';
      
      // Try combining with number elements
      for (int i = 0; i < numberElements.length && i < 3; i++) {
        final numbers = numberElements.sublist(0, i + 1).map((e) => e.text).join('');
        final candidate = '$letters$numbers';
        
        if (_isValid(candidate)) return candidate;
        
        // Try with character correction
        final corrected = _fix(candidate);
        if (corrected != null && _isValid(corrected)) return corrected;
      }

      // Also try just letters + all nearby numbers combined
      final allNumbers = numberElements.take(3).map((e) => e.text).join('');
      if (allNumbers.isNotEmpty) {
        final candidate = '$letters$allNumbers';
        if (_isValid(candidate)) return candidate;
        
        final corrected = _fix(candidate);
        if (corrected != null && _isValid(corrected)) return corrected;
      }
    }

    return null;
  }

  /// Detect conduction sticker from any combination of fragments
  String? _detectConductionFromFragments(List<OcrElement> elements) {
    // Get all text fragments, sorted by position (top-left to bottom-right)
    final sorted = List<OcrElement>.from(elements)..sort((a, b) {
      // Sort by Y first (rows), then X (columns)
      final yDiff = (a.top - b.top).abs();
      if (yDiff < 20) return a.left.compareTo(b.left);
      return a.top.compareTo(b.top);
    });

    // Try combining fragments in different ways
    final allText = sorted.map((e) => e.text).join('');
    
    // Look for conduction pattern: 2 letters followed by 4 digits
    for (int i = 0; i < allText.length - 5; i++) {
      for (int len = 6; len <= 7 && i + len <= allText.length; len++) {
        final substring = allText.substring(i, i + len);
        if (_isValid(substring)) return substring;
        
        final corrected = _fix(substring);
        if (corrected != null && _isValid(corrected)) return corrected;
      }
    }

    return null;
  }

  /// Try to find a valid plate of exactly [len] characters from the given tokens.
  String? _tryTokensForLen(List<String> tokens, int len) {
    // 1. Try exact length tokens first
    for (final token in tokens) {
      if (token.length >= len) {
        for (int i = 0; i <= token.length - len; i++) {
          final substring = token.substring(i, i + len);
          if (_isValid(substring)) return substring;
          final fixed = _fix(substring);
          if (fixed != null) return fixed;
          final dbMatch = _fuzzySearchDb(substring);
          if (dbMatch != null) return dbMatch;
        }
      }
    }
    
    // 2. Try joining tokens (e.g. "DBA" + "4658" -> "DBA4658")
    final joined = tokens.where((t) => t.length <= 8).join('');
    if (joined.length >= len) {
      for (int i = 0; i <= joined.length - len; i++) {
        final substring = joined.substring(i, i + len);
        if (_isValid(substring)) return substring;
        final fixed = _fix(substring);
        if (fixed != null) return fixed;
        final dbMatch = _fuzzySearchDb(substring);
        if (dbMatch != null) return dbMatch;
      }
    }
    return null;
  }

  /// Fuzzy search DB for a read that almost matches a known plate
  String? _fuzzySearchDb(String read) {
    if (_dbPlates.isEmpty) return null;
    
    // Case 1: Exact match in DB but maybe failing regex
    if (_dbPlates.contains(read)) return read;
    
    // Case 2: 1-character difference (Levenshtein distance 1)
    // Only search plates of similar length
    for (final plate in _dbPlates) {
      if ((plate.length - read.length).abs() > 1) continue;
      if (_levenshtein(read, plate) <= 1) {
        return plate;
      }
    }
    return null;
  }

  /// Simple Levenshtein distance calculation
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
      for (int j = 0; j < v0.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v0[t.length];
  }

  // Position-aware correction: letter zone → force letter, digit zone → force digit
  String? _fix(String s) {
    const toL = {'0':'O','1':'I','8':'B','5':'S','2':'Z','6':'G','4':'A','7':'T'};
    const toD = {'O':'0','I':'1','B':'8','S':'5','Z':'2','G':'6','Q':'0','A':'4','T':'7'};
    String L(String c) => toL[c] ?? c;
    String D(String c) => toD[c] ?? c;
    bool isLetter(String c) => c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90;

    if (s.length == 7) {
      // New plate [L L L D D D D]
      final f = '${L(s[0])}${L(s[1])}${L(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}${D(s[6])}';
      if (_isValid(f)) return f;
      // Conduction with trailing letter [L L D D D D L]
      final l0 = L(s[0]); final l1 = L(s[1]);
      if (isLetter(l0) && isLetter(l1)) {
        final f2 = '$l0$l1${D(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}${L(s[6])}';
        if (_isValid(f2)) return f2;
      }
    }
    if (s.length == 6) {
      // Old plate [L L L D D D]
      final f = '${L(s[0])}${L(s[1])}${L(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}';
      if (_isValid(f)) return f;
      // Conduction [L L D D D D]
      final l0 = L(s[0]); final l1 = L(s[1]);
      if (isLetter(l0) && isLetter(l1)) {
        final f2 = '$l0$l1${D(s[2])}${D(s[3])}${D(s[4])}${D(s[5])}';
        if (_isValid(f2)) return f2;
      }
    }
    return null;
  }

  // ── DB search ─────────────────────────────────────────────────
  Future<List<VehicleModel>> _dbSearch(String plate) async {
    plate = plate.toUpperCase();

    // Fast path: cached results
    final cached = _dbSearchCache[plate];
    if (cached != null) return cached;

    const swaps = {'B':'8','8':'B','O':'0','0':'O','I':'1','1':'I',
                   'S':'5','5':'S','Z':'2','2':'Z','G':'6','6':'G'};
    final variants = <String>{plate};
    for (int i = 0; i < plate.length; i++) {
      final alt = swaps[plate[i]];
      if (alt != null) variants.add(plate.substring(0,i)+alt+plate.substring(i+1));
    }

    final results = await Future.wait(
      variants.where(_isValid).map((v) => _db.searchVehicle(v)));
    final seen = <String>{}; final out = <VehicleModel>[];
    for (final list in results) {
      for (final v in list) {
        if (seen.add(v.plateNumber)) out.add(v);
      }
    }

    if (out.isNotEmpty) {
      _dbSearchCache[plate] = out;
    }

    return out;
  }

  // ── Show result ───────────────────────────────────────────────
  Future<void> _showResult(List<VehicleModel> vehicles, String plate) async {
    // Make sure the camera stream is stopped before presenting the result sheet.
    // This avoids any active callbacks or controllers remaining active while
    // the sheet is open (which can contribute to inherited widget assertion failures).
    await _stopStream();

    if (!mounted) return;

    // Show the result sheet and await the user's action. Returning a value
    // from the sheet keeps navigation logic centralized and avoids popping the
    // wrong navigator (which can lead to inherited widget assertion failures).
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: vehicles.isNotEmpty ? 0.88 : 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, __) => VehicleResultPopup(
          vehicles: vehicles,
          searchedPlate: plate,
          searchMode: SearchMode.camera,
          onScanAnother: () => Navigator.of(sheetContext).pop('scanAnother'),
          onTypeSearchAnother: () => Navigator.of(sheetContext).pop('typeSearch'),
          onScanAgain: () => Navigator.of(sheetContext).pop('scanAgain'),
          onBackToDashboard: () => Navigator.of(sheetContext).pop('back'),
        ),
      ),
    );

    if (!mounted) return;

    // Reset state after the sheet has been dismissed.
    _resetState();

    // Handle optional navigation actions (e.g. returning to dashboard).
    if (action == 'typeSearch') {
      Navigator.of(context).pop('typeSearch');
    } else if (action == 'back') {
      Navigator.of(context).pop();
    }
  }

  void _resetState() {
    if (!mounted) return;
    setState(() {
      _resultShown = false; _manualBusy = false;
      _reading = null; _noRecordMsg = null;
      _streakPlate = null; _streakCount = 0;
      _hint = 'Align plate inside the frame';
    });
    _startStream();
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 56),
          const SizedBox(height: 16),
          const Text('Camera scanning is not available on web.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: () => Navigator.pop(context),
              child: const Text('Go Back')),
        ])),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // Camera preview
        if (_cameraReady && _ctrl != null)
          Positioned.fill(child: CameraPreview(_ctrl!))
        else if (_cameraError != null) _errorWidget()
        else const Center(child: CircularProgressIndicator(color: Color(0xFFFF0000))),

        // Dark overlay with frame cutout
        if (_cameraReady)
          Positioned.fill(child: CustomPaint(painter: _OverlayPainter())),

        // ── Auto-scan format pills ────────────────────────────
        if (_cameraReady && !_manualBusy)
          Positioned(
            bottom: 180, left: 0, right: 0,
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

        // Animated scan frame + streak dots (shifted slightly upward)
        if (_cameraReady)
          Align(alignment: const Alignment(0, _kFrameYOffsetFraction),
              child: _ScanFrame(
                  streakCount: _streakCount,
                  threshold: _kStreak,
                  hasReading: _reading != null,
                  isScanning: _isScanning)),

        // ── Top bar ───────────────────────────────────────────
        SafeArea(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            _iconBtn(Icons.arrow_back_ios_rounded, () => Navigator.pop(context)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Scan Plate / Conduction Sticker',
                  style: TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
            // Auto-scan indicator badge (top right)
            _AutoBadge(isScanning: _isScanning, streakCount: _streakCount),
          ]),
        )),

        // ── Centre: format pills + status + no-record message ──
        if (_cameraReady)
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Format pills
            Row(mainAxisSize: MainAxisSize.min, children: const [
              _Pill(label: 'PLATE', example: 'NHM4030'),
              SizedBox(width: 8),
              _Pill(label: 'CS', example: 'RB0827'),
            ]),
            const SizedBox(height: 10),
            const SizedBox(height: _kFrameH),
            const SizedBox(height: 14),

            // Status bubble (reading + streak bar OR hint)
            _StatusBubble(
              reading: _reading,
              hint: _hint,
              streakCount: _streakCount,
              threshold: _kStreak,
              busy: _manualBusy,
            ),

            // No-record inline message (auto-scan only)
            if (_apiBusy) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[900]!.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.blue[300]!, width: 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 12, height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 10),
                  const Text('AI Enhancing...', 
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ]),
              ),
            ],

            if (_noRecordMsg != null) ...[
              const SizedBox(height: 10),
              _NoRecordBanner(message: _noRecordMsg!),
            ],
          ])),

        // ── Bottom: manual shutter (always visible) ────────────
        if (_cameraReady)
          Positioned(
            bottom: 44, left: 0, right: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Tip text
              Text(
                _manualBusy
                    ? _hint
                    : 'Auto-scanning  •  Tap to capture manually',
                style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),

              // Shutter button — always active (both auto + manual coexist)
              GestureDetector(
                onTap: _manualBusy || _resultShown ? null : _manualCapture,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_manualBusy || _resultShown)
                        ? Colors.grey[700]
                        : const Color(0xFFFF0000),
                    border: Border.all(color: Colors.white, width: 3.5),
                    boxShadow: (!_manualBusy && !_resultShown) ? [
                      BoxShadow(color: const Color(0xFFFF0000).withOpacity(0.45),
                          blurRadius: 20, spreadRadius: 3),
                    ] : [],
                  ),
                  child: _manualBusy
                      ? const Padding(padding: EdgeInsets.all(22),
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white))
                      : const Icon(Icons.camera_alt_rounded,
                          color: Colors.white, size: 30),
                ),
              ),
              const SizedBox(height: 8),
              Text('Manual capture',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.35), fontSize: 10)),
            ]),
          ),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.black54,
          borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: Colors.white, size: 18),
    ),
  );

  Widget _errorWidget() => Center(
    child: Padding(padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.camera_alt_outlined, color: Colors.grey, size: 56),
        const SizedBox(height: 16),
        Text(_cameraError!, style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: () => Navigator.pop(context),
            child: const Text('Go Back')),
      ]),
    ),
  );

  /// Crop image bytes using dart:ui (mobile)
  Future<Uint8List?> _cropImage(Uint8List bytes, int l, int t, int r, int b) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final fullImg = frame.image;

      final srcX = l.toDouble().clamp(0.0, fullImg.width.toDouble());
      final srcY = t.toDouble().clamp(0.0, fullImg.height.toDouble());
      final srcW = (r - l).toDouble().clamp(1.0, fullImg.width.toDouble() - srcX);
      final srcH = (b - t).toDouble().clamp(1.0, fullImg.height.toDouble() - srcY);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      
      canvas.drawImageRect(
        fullImg,
        Rect.fromLTWH(srcX, srcY, srcW, srcH),
        Rect.fromLTWH(0, 0, srcW, srcH),
        Paint(),
      );

      final picture = recorder.endRecording();
      final croppedImg = await picture.toImage(srcW.toInt(), srcH.toInt());
      final byteData = await croppedImg.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      print('Crop error: $e');
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────────

// Auto-scan badge (top right)
class _AutoBadge extends StatefulWidget {
  final bool isScanning;
  final int streakCount;
  const _AutoBadge({required this.isScanning, required this.streakCount});
  @override State<_AutoBadge> createState() => _AutoBadgeState();
}
class _AutoBadgeState extends State<_AutoBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _dot;
  @override void initState() {
    super.initState();
    _dot = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600))..repeat(reverse: true);
  }
  @override void dispose() { _dot.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final color = widget.isScanning
        ? Color.lerp(const Color(0xFFFF0000), Colors.orange, _dot.value)!
        : widget.streakCount > 0
            ? const Color(0xFFFFAA00)
            : Colors.white38;
    return AnimatedBuilder(
      animation: _dot,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color,
              boxShadow: widget.isScanning ? [
                BoxShadow(color: color.withOpacity(0.6), blurRadius: 6)] : [])),
          const SizedBox(width: 5),
          Text(
            widget.isScanning ? 'Scanning' : widget.streakCount > 0 ? 'Reading' : 'Auto',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ]),
      ),
    );
  }
}

// Scan frame with streak dots
class _ScanFrame extends StatefulWidget {
  final int streakCount, threshold;
  final bool hasReading, isScanning;
  const _ScanFrame({required this.streakCount, required this.threshold,
      required this.hasReading, required this.isScanning});
  @override State<_ScanFrame> createState() => _ScanFrameState();
}
class _ScanFrameState extends State<_ScanFrame>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  @override void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  }
  @override void dispose() { _pulse.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final active  = widget.hasReading || widget.isScanning;
    final color   = widget.hasReading ? const Color(0xFFFFAA00)
        : widget.isScanning ? const Color(0xFFFF4444) : Colors.white;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Streak confidence dots
      if (widget.hasReading)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(mainAxisSize: MainAxisSize.min,
            children: List.generate(widget.threshold, (i) {
              final lit = i < widget.streakCount;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: lit ? 12 : 7, height: lit ? 12 : 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lit ? const Color(0xFFFFAA00) : Colors.white24,
                  boxShadow: lit ? [BoxShadow(
                    color: const Color(0xFFFFAA00).withOpacity(0.7),
                    blurRadius: 8, spreadRadius: 1)] : [],
                ),
              );
            }),
          ),
        ),
      // Frame brackets
      AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => Opacity(
          opacity: active ? 0.5 + _pulse.value * 0.5 : 1.0,
          child: SizedBox(width: _kFrameW, height: _kFrameH,
              child: CustomPaint(painter: _BracketPainter(color: color))),
        ),
      ),
    ]);
  }
}

// Status bubble
class _StatusBubble extends StatelessWidget {
  final String? reading;
  final String hint;
  final int streakCount, threshold;
  final bool busy;
  const _StatusBubble({required this.reading, required this.hint,
      required this.streakCount, required this.threshold, required this.busy});

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: reading != null ? _readingWidget() : _hintWidget(),
  );

  Widget _readingWidget() => Container(
    key: ValueKey(reading),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.82),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFFFAA00).withOpacity(0.8), width: 1.5),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFAA00))),
        const SizedBox(width: 8),
        Text(reading!, style: const TextStyle(color: Colors.white,
            fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 4)),
      ]),
      const SizedBox(height: 7),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Confirming  ', style: TextStyle(color: Colors.white54, fontSize: 10)),
        ...List.generate(threshold, (i) => AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(left: 3),
          width: 22, height: 4,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: i < streakCount ? const Color(0xFFFFAA00) : Colors.white,
          ),
        )),
        const SizedBox(width: 6),
        Text('$streakCount/$threshold',
            style: const TextStyle(color: Color(0xFFFFAA00),
                fontSize: 10, fontWeight: FontWeight.w700)),
      ]),
    ]),
  );

  Widget _hintWidget() => Container(
    key: const ValueKey('hint'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
        color: Colors.black, borderRadius: BorderRadius.circular(28)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (busy) ...[
        const SizedBox(width: 13, height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF0000))),
        const SizedBox(width: 8),
      ],
      Text(hint, style: const TextStyle(color: Colors.white, fontSize: 13)),
    ]),
  );
}

// No-record banner (auto-scan inline)
class _NoRecordBanner extends StatelessWidget {
  final String message;
  const _NoRecordBanner({required this.message});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.red[900]!.withOpacity(0.88),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Colors.red[400]!, width: 1),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.search_off_rounded, color: Colors.white70, size: 16),
      const SizedBox(width: 8),
      Text(message,
          style: const TextStyle(color: Colors.white,
              fontSize: 13, fontWeight: FontWeight.w600)),
    ]),
  );
}

// ── Painters ──────────────────────────────────────────────────────
class _OverlayPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(
            (size.width - _kFrameW) / 2,
            (size.height - _kFrameH) / 2 + (size.height / 2) * _kFrameYOffsetFraction,
            _kFrameW,
            _kFrameH,
          ),
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
    canvas.drawLine(Offset(w-len, 0), Offset(w, 0), p);
    canvas.drawLine(Offset(w, 0), Offset(w, len), p);
    canvas.drawLine(Offset(0, h-len), Offset(0, h), p);
    canvas.drawLine(Offset(0, h), Offset(len, h), p);
    canvas.drawLine(Offset(w-len, h), Offset(w, h), p);
    canvas.drawLine(Offset(w, h), Offset(w, h-len), p);
    
    // Middle horizontal guide line
    final midPaint = Paint()
      ..color = color.withOpacity(0.5)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dashWidth = 8.0;
    const dashSpace = 6.0;
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

// ── Confirm dialog widget ─────────────────────────────────────────
class _ConfirmDialog extends StatefulWidget {
  final String detected;
  const _ConfirmDialog({required this.detected});

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.detected);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Confirm Plate Number',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 16),
            Text(
              widget.detected.isEmpty
                  ? 'No plate detected. Type it manually:'
                  : 'Scanner read this plate.\nCorrect it if needed:',
              style: TextStyle(color: Colors.grey[600], fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 5,
                  color: Color(0xFF1A1A1A)),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                helperText: 'Plate: NHM4030   Conduction: RB0827',
                helperStyle:
                    TextStyle(color: Colors.grey[400], fontSize: 11),
              ),
            ),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () {
                  final v = _controller.text
                      .toUpperCase()
                      .replaceAll(RegExp(r'[^A-Z0-9]'), '');
                  Navigator.of(context).pop(v.isEmpty ? null : v);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF0000),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('Search',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label, example;
  const _Pill({required this.label, required this.example});
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFFF0000),
            borderRadius: BorderRadius.circular(4)),
        child: Text(label, style: const TextStyle(color: Colors.white,
            fontSize: 9, fontWeight: FontWeight.w800)),
      ),
      const SizedBox(width: 6),
      Text(example, style: const TextStyle(color: Colors.white70,
          fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1)),
    ]),
  );
}