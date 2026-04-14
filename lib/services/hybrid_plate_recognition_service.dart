import 'dart:typed_data';
import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'offline_plate_detection_service.dart';
import 'image_preprocessing_service.dart';
import 'firestore_service.dart';

/// Complete result of the plate recognition pipeline
class PlateRecognitionResult {
  final String plateNumber;
  final double confidence;
  final String? croppedImagePath;
  final bool isOfflineMode;

  PlateRecognitionResult({
    required this.plateNumber,
    required this.confidence,
    this.croppedImagePath,
    this.isOfflineMode = true,
  });
}

/// Hybrid offline plate recognition pipeline
/// Uses TFLite for detection, image processing, and ML Kit OCR
class HybridPlateRecognitionService {
  final OfflinePlateDetectionService _detectionService;
  final ImagePreprocessingService _preprocessingService;
  final TextRecognizer _ocr = TextRecognizer();
  final FirestoreService _firestoreService;
  
  bool _isInitialized = false;

  HybridPlateRecognitionService()
      : _detectionService = OfflinePlateDetectionService(),
        _preprocessingService = ImagePreprocessingService(),
        _firestoreService = FirestoreService();

  bool get isInitialized => _isInitialized;

  /// Initialize all services
  Future<void> initialize() async {
    try {
      await _detectionService.initialize();
      _isInitialized = true;
      print('Hybrid Plate Recognition initialized (offline mode)');
    } catch (e) {
      print('Failed to initialize hybrid service: $e');
      _isInitialized = false;
    }
  }

  /// Process an image and recognize the plate number
  /// Full pipeline: Detection -> Crop -> Preprocess -> OCR -> Validate
  Future<PlateRecognitionResult?> processImage(
    Uint8List imageBytes, {
    bool saveToFirestore = true,
    bool saveCroppedImage = true,
  }) async {
    if (!_isInitialized) {
      print('Service not initialized');
      return null;
    }

    try {
      // Step 1: Detect plate using TFLite
      final detections = await _detectionService.detectPlates(imageBytes);
      
      if (detections.isEmpty) {
        print('No plate detected by TFLite');
        return null;
      }

      // Get best detection
      final bestDetection = _detectionService.getBestDetection(detections);
      if (bestDetection == null) {
        return null;
      }

      // Step 2: Crop to bounding box
      final croppedBytes = await _preprocessingService.cropToBoundingBox(
        imageBytes,
        bestDetection.x.toInt(),
        bestDetection.y.toInt(),
        bestDetection.width.toInt(),
        bestDetection.height.toInt(),
      );

      if (croppedBytes == null) {
        print('Failed to crop image');
        return null;
      }

      // Step 3: Preprocess the cropped image
      final processed = await _preprocessingService.preprocess(croppedBytes);
      
      if (processed == null) {
        print('Failed to preprocess image');
        return null;
      }

      // Step 4: Save processed image temporarily for OCR
      final tempPath = await _saveTempImage(processed.processedBytes);
      if (tempPath == null) {
        print('Failed to save temp image');
        return null;
      }

      // Step 5: Run OCR
      final inputImage = InputImage.fromFilePath(tempPath);
      final ocrResult = await _ocr.processImage(inputImage);
      
      // Clean up temp file
      try { File(tempPath).deleteSync(); } catch (_) {}

      if (ocrResult.text.isEmpty) {
        print('OCR failed to recognize text');
        return null;
      }

      // Step 6: Validate and clean plate number
      final plateNumber = _cleanOcrText(ocrResult.text);
      if (!_isValidPlateFormat(plateNumber)) {
        print('Invalid plate format: $plateNumber');
        return null;
      }

      // Step 7: Save cropped image if requested
      String? croppedPath;
      if (saveCroppedImage) {
        croppedPath = await _saveCroppedImage(processed.processedBytes, plateNumber);
      }

      // Step 8: Save to Firestore if requested
      if (saveToFirestore && croppedPath != null) {
        await _saveToFirestore(plateNumber, croppedPath, bestDetection.confidence);
      }

      return PlateRecognitionResult(
        plateNumber: plateNumber,
        confidence: bestDetection.confidence,
        croppedImagePath: croppedPath,
        isOfflineMode: true,
      );
    } catch (e) {
      print('Plate recognition error: $e');
      return null;
    }
  }

  /// Clean OCR output to extract plate number
  String _cleanOcrText(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceAll(' ', '').replaceAll('\n', '').replaceAll('\r', '');
    cleaned = cleaned.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return cleaned.toUpperCase();
  }

  /// Validate Philippine plate format
  bool _isValidPlateFormat(String text) {
    final newPlate = RegExp(r'^[A-Z]{3}[0-9]{4}$');
    final oldPlate = RegExp(r'^[A-Z]{3}[0-9]{3}$');
    final conduction = RegExp(r'^[A-Z]{2}[0-9]{4}[A-Z]?$');
    return newPlate.hasMatch(text) || oldPlate.hasMatch(text) || conduction.hasMatch(text);
  }

  /// Save temporary image for OCR processing
  Future<String?> _saveTempImage(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${dir.path}/temp_ocr_$timestamp.png';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      return filePath;
    } catch (e) {
      print('Error saving temp image: $e');
      return null;
    }
  }

  /// Save cropped plate image to local storage
  Future<String?> _saveCroppedImage(Uint8List imageBytes, String plateNumber) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'plate_${plateNumber}_$timestamp.png';
      final filePath = '${dir.path}/$fileName';
      
      final file = File(filePath);
      await file.writeAsBytes(imageBytes);
      
      return filePath;
    } catch (e) {
      print('Error saving cropped image: $e');
      return null;
    }
  }

  /// Save recognition result to Firestore
  Future<void> _saveToFirestore(
    String plateNumber,
    String imagePath,
    double confidence,
  ) async {
    try {
      await _firestoreService.saveScanRecord({
        'plateNumber': plateNumber,
        'imagePath': imagePath,
        'confidence': confidence,
        'timestamp': DateTime.now(),
        'isOfflineMode': true,
      });
    } catch (e) {
      print('Error saving to Firestore: $e');
    }
  }

  /// Dispose all resources
  void dispose() {
    _detectionService.dispose();
    _ocr.close();
    _isInitialized = false;
  }
}
