import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Detection result from Roboflow AI model
class PlateDetection {
  final double x;      // Center X coordinate
  final double y;      // Center Y coordinate
  final double width;
  final double height;
  final double confidence;
  final String? className;

  PlateDetection({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    this.className,
  });

  /// Get bounding box as integer coordinates (left, top, right, bottom)
  (int left, int top, int right, int bottom) get boundingBox {
    final left = (x - width / 2).round();
    final top = (y - height / 2).round();
    final right = (x + width / 2).round();
    final bottom = (y + height / 2).round();
    return (left, top, right, bottom);
  }
}

/// Service for Roboflow AI license plate detection
class RoboflowService {
  // IMPORTANT: Replace with your actual Roboflow API key
  // Get it from: https://app.roboflow.com/settings/api
  static const String _apiKey = 'rf_0VlcLzTUCMc5G6kgVw1toAjIR8w2';
  
  // Model endpoint - alpr-conduction-sticker (optimized for conduction stickers)
  // Workspace: alpr-b2zd3, Model: alpr-conduction-sticker, Version: 3
  // Free tier: 1,000 inferences/month
  static const String _modelId = 'alpr-b2zd3/alpr-conduction-sticker';
  static const int _modelVersion = 3;
  
  static const String _baseUrl = 'https://detect.roboflow.com';

  /// Detect license plates in image bytes
  /// Returns list of detected plates with bounding boxes
  Future<List<PlateDetection>> detectPlates(dynamic imageData) async {
    try {
      final url = Uri.parse(
        '$_baseUrl/$_modelId/$_modelVersion?api_key=$_apiKey'
      );

      // Create multipart request
      final request = http.MultipartRequest('POST', url);
      
      // Handle both Uint8List and List<int>
      final bytes = imageData is Uint8List ? imageData : Uint8List.fromList(imageData as List<int>);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'image.jpg',
        ),
      );

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return _parseResponse(response.body);
      } else {
        // Log error but don't crash - fall back to existing OCR
        print('Roboflow API error: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      // Network error or other issue - fall back to existing OCR
      print('Roboflow detection error: $e');
      return [];
    }
  }

  /// Parse the Roboflow API response
  List<PlateDetection> _parseResponse(String responseBody) {
    try {
      final Map<String, dynamic> data = json.decode(responseBody);
      
      final predictions = data['predictions'] as List<dynamic>?;
      if (predictions == null || predictions.isEmpty) {
        return [];
      }

      return predictions.map((pred) {
        return PlateDetection(
          x: (pred['x'] as num).toDouble(),
          y: (pred['y'] as num).toDouble(),
          width: (pred['width'] as num).toDouble(),
          height: (pred['height'] as num).toDouble(),
          confidence: (pred['confidence'] as num?)?.toDouble() ?? 0.0,
          className: pred['class'] as String?,
        );
      }).toList();
    } catch (e) {
      print('Error parsing Roboflow response: $e');
      return [];
    }
  }

  /// Get the best (highest confidence) detection
  PlateDetection? getBestDetection(List<PlateDetection> detections) {
    if (detections.isEmpty) return null;
    
    PlateDetection? best;
    double highestConfidence = 0;
    
    for (final detection in detections) {
      if (detection.confidence > highestConfidence) {
        highestConfidence = detection.confidence;
        best = detection;
      }
    }
    
    return best;
  }

}
