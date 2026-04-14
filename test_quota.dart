import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  const String _apiToken = '7ff33db4a1e211bb79da90e1ef434cc15a1a6658';
  const String _apiUrl = 'https://api.platerecognizer.com/v1/statistics/';

  try {
    final response = await http.get(
      Uri.parse(_apiUrl),
      headers: {'Authorization': 'Token $_apiToken'},
    );

    final data = jsonDecode(response.body);
    print('Total quota: ${data['total_calls']}');
    print('Current usage: ${data['usage']['month']['calls']}');

  } catch (e) {
    print('Error: $e');
  }
}
