import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Result of image preprocessing
class PreprocessedImage {
  final Uint8List processedBytes;
  final int width;
  final int height;

  PreprocessedImage({
    required this.processedBytes,
    required this.width,
    required this.height,
  });
}

/// Service for preprocessing cropped plate images before OCR
class ImagePreprocessingService {
  // Standard output size for regular plates
  static const int _targetWidth = 300;
  static const int _targetHeight = 100;
  
  // Output size optimized for conduction stickers (more square for vertical layout)
  static const int _conductionTargetWidth = 200;
  static const int _conductionTargetHeight = 150;
  
  // Threshold values for binarization
  static const int _threshold = 128;

  /// Process a cropped plate image for better OCR accuracy
  /// Steps: grayscale -> contrast enhancement -> thresholding -> resize
  Future<PreprocessedImage?> preprocess(Uint8List imageBytes) async {
    try {
      // Decode image
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      // Step 1: Convert to grayscale
      final grayscale = img.grayscale(image);

      // Step 2: Apply contrast enhancement
      final contrasted = img.adjustColor(grayscale, contrast: 1.5);

      // Step 3: Apply thresholding (binarization)
      final thresholded = img.luminanceThreshold(contrasted, threshold: _threshold / 255.0);

      // Step 4: Resize to standard size for OCR
      final resized = img.copyResize(
        thresholded,
        width: _targetWidth,
        height: _targetHeight,
        interpolation: img.Interpolation.linear,
      );

      // Step 5: Apply slight sharpening for better text clarity
      final sharpened = img.convolution(resized, filter: [
        0, -1, 0,
        -1, 5, -1,
        0, -1, 0,
      ]);

      // Encode to PNG
      final processedBytes = Uint8List.fromList(img.encodePng(sharpened));

      return PreprocessedImage(
        processedBytes: processedBytes,
        width: sharpened.width,
        height: sharpened.height,
      );
    } catch (e) {
      print('Image preprocessing error: $e');
      return null;
    }
  }

  /// Quick preprocess - just grayscale and resize (faster)
  Future<PreprocessedImage?> quickPreprocess(Uint8List imageBytes) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      // Convert to grayscale and resize
      final grayscale = img.grayscale(image);
      final resized = img.copyResize(
        grayscale,
        width: _targetWidth,
        height: _targetHeight,
      );

      final processedBytes = Uint8List.fromList(img.encodePng(resized));

      return PreprocessedImage(
        processedBytes: processedBytes,
        width: resized.width,
        height: resized.height,
      );
    } catch (e) {
      print('Quick preprocessing error: $e');
      return null;
    }
  }

  /// Crop image to bounding box
  Future<Uint8List?> cropToBoundingBox(
    Uint8List imageBytes,
    int left,
    int top,
    int width,
    int height, {
    int padding = 10,
  }) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      // Add padding
      final paddedLeft = (left - padding).clamp(0, image.width - 1);
      final paddedTop = (top - padding).clamp(0, image.height - 1);
      final paddedWidth = (width + padding * 2).clamp(1, image.width - paddedLeft);
      final paddedHeight = (height + padding * 2).clamp(1, image.height - paddedTop);

      // Crop
      final cropped = img.copyCrop(
        image,
        x: paddedLeft,
        y: paddedTop,
        width: paddedWidth,
        height: paddedHeight,
      );

      return Uint8List.fromList(img.encodePng(cropped));
    } catch (e) {
      print('Crop error: $e');
      return null;
    }
  }

  /// Preprocess image optimized for conduction stickers
  /// Conduction stickers have vertical letters + horizontal numbers layout
  /// This method preserves more vertical space for better letter detection
  Future<PreprocessedImage?> preprocessForConductionSticker(Uint8List imageBytes) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      // Step 1: Convert to grayscale
      final grayscale = img.grayscale(image);

      // Step 2: Apply stronger contrast enhancement for conduction stickers
      // They often have lower contrast between text and background
      final contrasted = img.adjustColor(grayscale, contrast: 1.8, brightness: 10);

      // Step 3: Apply adaptive thresholding for better text separation
      final thresholded = img.luminanceThreshold(contrasted, threshold: 0.45);

      // Step 4: Resize to conduction-optimized size (more square aspect ratio)
      final resized = img.copyResize(
        thresholded,
        width: _conductionTargetWidth,
        height: _conductionTargetHeight,
        interpolation: img.Interpolation.linear,
      );

      // Step 5: Apply aggressive sharpening for text clarity
      final sharpened = img.convolution(resized, filter: [
        -1, -1, -1,
        -1,  9, -1,
        -1, -1, -1,
      ]);

      // Encode to PNG
      final processedBytes = Uint8List.fromList(img.encodePng(sharpened));

      return PreprocessedImage(
        processedBytes: processedBytes,
        width: sharpened.width,
        height: sharpened.height,
      );
    } catch (e) {
      print('Conduction sticker preprocessing error: $e');
      return null;
    }
  }

  /// Detect if an image might contain a conduction sticker based on aspect ratio
  /// Conduction stickers are typically more square-ish compared to wide regular plates
  static bool isLikelyConductionSticker(int width, int height) {
    final aspectRatio = width / height;
    // Regular plates are wide (aspect ratio ~3:1)
    // Conduction stickers are more square (aspect ratio ~1.5:1 or less)
    return aspectRatio < 2.0;
  }
}
