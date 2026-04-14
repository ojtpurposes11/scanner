import 'dart:typed_data';

/// Detection result placeholder for future TFLite model integration
/// Currently falls back to existing ML Kit OCR in camera scanner
class TFLiteDetection {
  final double x;
  final double y;
  final double width;
  final double height;
  final double confidence;
  final int labelIndex;
  final String label;

  TFLiteDetection({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    required this.labelIndex,
    required this.label,
  });

  /// Get bounding box as integer coordinates for a given image size
  (int left, int top, int right, int bottom) getBoundingBox(int imgW, int imgH) {
    final left = ((x - width / 2) * imgW).round().clamp(0, imgW);
    final top = ((y - height / 2) * imgH).round().clamp(0, imgH);
    final right = ((x + width / 2) * imgW).round().clamp(0, imgW);
    final bottom = ((y + height / 2) * imgH).round().clamp(0, imgH);
    return (left, top, right, bottom);
  }
}

/// Offline plate detection service placeholder
/// Uses existing ML Kit OCR in camera scanner for now
/// To add TFLite: add tflite_flutter to pubspec.yaml and implement detection
class OfflinePlateDetectionService {
  bool _isInitialized = false;
  
  // Detection thresholds
  static const double _confidenceThreshold = 0.5;

  bool get isInitialized => _isInitialized;

  /// Initialize the service (placeholder for future TFLite)
  Future<void> initialize() async {
    // TFLite removed due to build issues
    // The app uses existing ML Kit OCR in camera scanner
    _isInitialized = false;
    print('TFLite not available - using ML Kit OCR fallback');
  }

  /// Detect plates - returns empty list (uses ML Kit fallback instead)
  Future<List<TFLiteDetection>> detectPlates(Uint8List imageBytes) async {
    // This service is disabled
    // The camera scanner uses ML Kit OCR directly
    return [];
  }

  /// Get the best detection
  TFLiteDetection? getBestDetection(List<TFLiteDetection> detections) {
    if (detections.isEmpty) return null;
    return detections.first;
  }

  /// Close the service
  void dispose() {
    _isInitialized = false;
  }
}
