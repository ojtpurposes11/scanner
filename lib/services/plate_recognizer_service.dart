import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Result from Plate Recognizer API
class PlateRecognizerResult {
  final String plate;
  final double confidence;
  final String? region;
  final String? vehicleType;

  PlateRecognizerResult({
    required this.plate,
    required this.confidence,
    this.region,
    this.vehicleType,
  });
}

/// Service for Plate Recognizer Snapshot API (LPR/ANPR)
/// Free tier: 2,500 monthly requests at https://platerecognizer.com/
class PlateRecognizerService {
  // Use environment variable for API token
  static String get _apiToken => dotenv.env['PLATE_RECOGNIZER_TOKEN'] ?? '';
  
  static const String _apiUrl = 'https://api.platerecognizer.com/v1/plate-reader/';

  /// Read license plate from image bytes using Plate Recognizer API
  Future<PlateRecognizerResult?> readPlate(Uint8List imageBytes) async {
    try {
      final request = http.MultipartRequest('POST', Uri.parse(_apiUrl));
      
      // Set Auth header
      request.headers['Authorization'] = 'Token $_apiToken';
      
      // Add image file
      request.files.add(
        http.MultipartFile.fromBytes(
          'upload', 
          imageBytes, 
          filename: 'scan.jpg'
        ),
      );
      
      // Removed regions: ph to avoid filtering out valid plates categorized as standard

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return _parseResponse(response.body);
      } else {
        print('Plate Recognizer API error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('Plate Recognizer network error: $e');
      return null;
    }
  }

  /// Parse the JSON response
  PlateRecognizerResult? _parseResponse(String responseBody) {
    try {
      final Map<String, dynamic> data = json.decode(responseBody);
      final results = data['results'] as List<dynamic>?;

      if (results == null || results.isEmpty) {
        return null;
      }

      final best = results[0]; // First result is highest confidence
      final plate = (best['plate'] as String? ?? '').toUpperCase();
      final score = (best['score'] as num? ?? 0.0).toDouble();
      
      if (plate.isEmpty) return null;

      // Extract region safely (API returns a Map: {"code": "ph", "score": ...})
      String? regionCode;
      if (best['region'] is Map) {
        regionCode = (best['region'] as Map)['code']?.toString();
      } else if (best['region'] is String) {
        regionCode = best['region'] as String;
      }

      return PlateRecognizerResult(
        plate: plate,
        confidence: score,
        region: regionCode,
        vehicleType: best['vehicle'] != null && best['vehicle'] is Map ? best['vehicle']['type'] as String? : null,
      );
    } catch (e) {
      print('Error parsing Plate Recognizer response: $e');
      return null;
    }
  }
}
