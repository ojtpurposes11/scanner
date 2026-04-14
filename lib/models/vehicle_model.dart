const List<String> _kHiddenFields = ['updatedAt', 'source'];

class VehicleModel {
  final String plateNumber;
  final String source;
  final Map<String, dynamic> rawData;

  VehicleModel({
    required this.plateNumber,
    required this.source,
    required this.rawData,
  });

  factory VehicleModel.fromFirestore(Map<String, dynamic> data, String docId) {
    // docId format: "PLATE_SOURCE" e.g. "FR858A_PSB"
    final lastUnderscore = docId.lastIndexOf('_');
    final plate =
        lastUnderscore > 0 ? docId.substring(0, lastUnderscore) : docId;
    final src = data['source']?.toString() ?? '';

    final raw = <String, dynamic>{};
    data.forEach((key, value) {
      if (_kHiddenFields.contains(key)) return;
      if (value == null) return;
      final str = value.toString().trim();
      if (str.isEmpty) return;
      raw[key] = str;
    });

    return VehicleModel(plateNumber: plate, source: src, rawData: raw);
  }

  List<MapEntry<String, String>> get displayFields {
    final entries = <MapEntry<String, String>>[];
    rawData.forEach((key, value) {
      if (_kHiddenFields.contains(key)) return;
      final str = value.toString().trim();
      if (str.isEmpty) return;
      entries.add(MapEntry(key, str));
    });
    return entries;
  }

  String get accountName => _getAny([
        'Acct. Name', 'ACCT NAME', 'Account Name', 'Name',
        'Client Name', 'Debtor', 'Customer', 'Borrower',
      ]);

  String get location => _getAny([
        'Location', 'PRIMARY ADDRESS', 'Address', 'Area', 'Region', 'City',
      ]);

  String get saturationLevel => _getAny([
        'Saturation Level', 'Saturation', 'Priority', 'BUCKET',
      ]);

  String _getAny(List<String> keys) {
    for (final key in keys) {
      final val = rawData[key]?.toString().trim() ?? '';
      if (val.isNotEmpty && val != 'N/A') return val;
    }
    return '';
  }
}

class UploadResult {
  final int added;
  final int updated;
  final int deleted;
  final int skipped;
  final int total;
  final List<String> skippedPlates;

  UploadResult({
    required this.added,
    required this.updated,
    required this.deleted,
    required this.skipped,
    required this.total,
    required this.skippedPlates,
  });
}