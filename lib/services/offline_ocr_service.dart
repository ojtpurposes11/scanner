import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Result of OCR processing
class OcrResult {
  final String text;
  final double confidence;

  OcrResult({
    required this.text,
    required this.confidence,
  });
}

/// Offline OCR service using Google ML Kit (works offline)
/// For full offline Tesseract OCR, additional native setup is required
class OfflineOcrService {
  final TextRecognizer _recognizer = TextRecognizer();
  bool _isInitialized = false;

  // Whitelist characters for Philippine plates (A-Z, 0-9)
  // Note: ML Kit doesn't support whitelist directly, but we filter results

  bool get isInitialized => _isInitialized;

  /// Initialize the OCR service
  Future<void> initialize() async {
    try {
      // ML Kit works offline after initial download
      _isInitialized = true;
      print('Offline OCR initialized (ML Kit)');
    } catch (e) {
      print('Failed to initialize OCR: $e');
      _isInitialized = false;
    }
  }

  /// Perform OCR on image bytes
  Future<OcrResult?> recognize(Uint8List imageBytes) async {
    if (!_isInitialized) {
      print('OCR not initialized');
      return null;
    }

    try {
      // Convert bytes to InputImage
      // For simplicity, we'll use a placeholder approach
      // In practice, you'd save bytes to temp file or use InputImage.fromBytes
      
      // Using ML Kit's built-in image from bytes
      // Note: ML Kit needs a proper InputImage, not raw bytes
      print('OCR processing not available for raw bytes - use InputImage');
      return null;
    } catch (e) {
      print('OCR error: $e');
      return null;
    }
  }

  /// Perform OCR on InputImage (from file path)
  Future<OcrResult?> recognizeFromInputImage(InputImage inputImage) async {
    if (!_isInitialized) return null;

    try {
      final result = await _recognizer.processImage(inputImage);
      
      if (result.text.isEmpty) return null;

      // Clean and filter the text
      final cleanedText = _cleanOcrText(result.text);
      
      if (cleanedText.isEmpty) return null;

      // Estimate confidence based on text quality
      final confidence = _estimateConfidence(result.text, cleanedText);

      return OcrResult(
        text: cleanedText,
        confidence: confidence,
      );
    } catch (e) {
      print('OCR error: $e');
      return null;
    }
  }

  /// Quick OCR with default settings
  Future<String?> quickRecognizeFromInputImage(InputImage inputImage) async {
    if (!_isInitialized) return null;

    try {
      final result = await _recognizer.processImage(inputImage);
      if (result.text.isEmpty) return null;
      return _cleanOcrText(result.text);
    } catch (e) {
      print('Quick OCR error: $e');
      return null;
    }
  }

  /// Clean OCR output to extract plate number
  String _cleanOcrText(String text) {
    // Remove whitespace
    var cleaned = text.trim();
    
    // Remove common OCR errors
    cleaned = cleaned
        .replaceAll(' ', '')
        .replaceAll('\n', '')
        .replaceAll('\r', '');
    
    // Keep only alphanumeric
    cleaned = cleaned.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    
    return cleaned.toUpperCase();
  }

  /// Estimate confidence based on text quality
  double _estimateConfidence(String rawText, String cleanedText) {
    if (cleanedText.isEmpty) return 0.0;
    if (rawText.isEmpty) return 0.0;
    
    // Simple heuristic: ratio of kept characters
    final ratio = cleanedText.length / rawText.length;
    return ratio.clamp(0.0, 1.0);
  }

  /// Validate if text looks like a Philippine plate number
  bool isValidPlateFormat(String text) {
    // New plate: ABC1234 (3 letters + 4 digits)
    final newPlate = RegExp(r'^[A-Z]{3}[0-9]{4}$');
    // Old plate: ABC123 (3 letters + 3 digits)
    final oldPlate = RegExp(r'^[A-Z]{3}[0-9]{3}$');
    // Conduction: AB1234 or AB1234C (2 letters + 4 digits + optional letter)
    final conduction = RegExp(r'^[A-Z]{2}[0-9]{4}[A-Z]?$');

    return newPlate.hasMatch(text) || 
           oldPlate.hasMatch(text) || 
           conduction.hasMatch(text);
  }

  /// Reconstruct conduction sticker text from fragmented OCR results
  /// Conduction stickers have vertical letters (AB) and horizontal numbers (1234)
  /// OCR may detect them as separate fragments
  String reconstructConductionSticker(List<Map<String, dynamic>> ocrResults) {
    if (ocrResults.isEmpty) return '';

    // Sort results by position (top to bottom, left to right)
    final sorted = List<Map<String, dynamic>>.from(ocrResults);
    
    // Extract all text and try to find the conduction pattern
    String allText = '';
    for (final result in sorted) {
      final text = (result['text'] as String?)?.toUpperCase() ?? '';
      final cleaned = text.replaceAll(RegExp(r'[^A-Z0-9]'), '');
      allText += cleaned;
    }

    // Look for conduction pattern: 2 letters followed by 4 digits
    final conductionPattern = RegExp(r'([A-Z]{2})([0-9]{4})');
    final match = conductionPattern.firstMatch(allText);
    if (match != null) {
      return match.group(0) ?? '';
    }

    // Try with optional trailing letter
    final conductionPatternWithSuffix = RegExp(r'([A-Z]{2})([0-9]{4})([A-Z]?)');
    final matchWithSuffix = conductionPatternWithSuffix.firstMatch(allText);
    if (matchWithSuffix != null) {
      return matchWithSuffix.group(0) ?? '';
    }

    return allText;
  }

  /// Dispose resources
  void dispose() {
    _recognizer.close();
    _isInitialized = false;
  }
}
