import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/vehicle_model.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const String _vehiclesCol = 'vehicles';
  static const String _sourcesCol = 'sources';
  static const String _scansCol = 'scans';

  // Doc ID = "PLATE_SOURCE" e.g. "FR858A_PSB"
  static String docId(String plate, String source) =>
      '${plate.toUpperCase()}_$source';

  // Plate validation: 6–7 alphanumeric chars
  static bool isValidPlate(String plate) {
    return plate.length >= 6 &&
        plate.length <= 7 &&
        RegExp(r'^[A-Z0-9]{6,7}$').hasMatch(plate);
  }

  // ── SOURCES ──────────────────────────────────

  Future<List<String>> getSources() async {
    try {
      final snap = await _db.collection(_sourcesCol).get();
      final sources = snap.docs.map((d) => d.id).toList();
      sources.sort();
      return sources;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSource(String sourceName) async {
    await _db.collection(_sourcesCol).doc(sourceName).set(
      {'createdAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  // ── SEARCH ───────────────────────────────────

  /// Returns ALL records matching this plate number across all sources.
  /// Empty list = not found.
  Future<List<VehicleModel>> searchVehicle(String plateNumber) async {
    try {
      final plate = plateNumber.toUpperCase().trim();

      // Doc IDs start with "PLATE_" — use range query to find them
      final snap = await _db
          .collection(_vehiclesCol)
          .where(FieldPath.documentId,
              isGreaterThanOrEqualTo: '${plate}_',
              isLessThan: '${plate}a') // 'a' > '_' in ASCII so this works
          .get();

      final results = <VehicleModel>[];
      for (final doc in snap.docs) {
        final lastUnderscore = doc.id.lastIndexOf('_');
        if (lastUnderscore < 0) continue;
        final docPlate = doc.id.substring(0, lastUnderscore);
        if (docPlate == plate && doc.data().isNotEmpty) {
          results.add(VehicleModel.fromFirestore(doc.data(), doc.id));
        }
      }
      return results;
    } catch (e) {
      throw Exception('Search failed: $e');
    }
  }

  // ── SYNC ─────────────────────────────────────

  /// Syncs vehicles for a specific source:
  /// - In file + not in DB  → ADD
  /// - In file + in DB      → UPDATE
  /// - In DB for this source + NOT in file → DELETE (settled)
  /// - Other sources        → UNTOUCHED
  Future<UploadResult> syncVehicles(
    List<Map<String, dynamic>> rows,
    String sourceName, {
    void Function(int done, int total, String stage)? onProgress,
  }) async {
    int added = 0;
    int updated = 0;
    int deleted = 0;
    int skipped = 0;
    final List<String> skippedPlates = [];
    const int batchSize = 400;
    final int total = rows.length;

    // Step 1: Build valid plate map from file
    final uploadedPlates = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final plate = (row['Plate #'] ?? '').toString().trim().toUpperCase();
      if (!isValidPlate(plate)) {
        skipped++;
        if (plate.isNotEmpty) skippedPlates.add(plate);
        continue;
      }
      uploadedPlates[plate] = row;
    }

    final validTotal = uploadedPlates.length;
    if (validTotal == 0) {
      return UploadResult(
        added: 0, updated: 0, deleted: 0,
        skipped: skipped, total: total,
        skippedPlates: skippedPlates,
      );
    }

    // Step 2: Fetch existing docs for THIS source only
    onProgress?.call(0, validTotal, 'Fetching existing records...');
    final existingSnap = await _db
        .collection(_vehiclesCol)
        .where('source', isEqualTo: sourceName)
        .get();

    // plate → docId for existing records of this source
    final existingPlates = <String, String>{};
    for (final doc in existingSnap.docs) {
      final lastUnderscore = doc.id.lastIndexOf('_');
      if (lastUnderscore < 0) continue;
      final plate = doc.id.substring(0, lastUnderscore);
      existingPlates[plate] = doc.id;
    }

    // Step 3: Write/update all plates from file
    onProgress?.call(0, validTotal, 'Saving records...');
    WriteBatch batch = _db.batch();
    int batchCount = 0;
    int processed = 0;

    for (final entry in uploadedPlates.entries) {
      final plate = entry.key;
      final row = entry.value;
      final id = docId(plate, sourceName);
      final isNew = !existingPlates.containsKey(plate);

      final data = <String, dynamic>{'source': sourceName};
      row.forEach((key, value) {
        if (key == 'Plate #') return;
        if (value == null) return;
        final str = value.toString().trim();
        if (str.isEmpty) return;
        data[key] = str;
      });
      data['updatedAt'] = FieldValue.serverTimestamp();

      batch.set(_db.collection(_vehiclesCol).doc(id), data);
      batchCount++;
      processed++;
      isNew ? added++ : updated++;

      if (batchCount >= batchSize) {
        await batch.commit();
        onProgress?.call(processed, validTotal, 'Saving records...');
        batch = _db.batch();
        batchCount = 0;
      }
      if (processed % 50 == 0) {
        onProgress?.call(processed, validTotal, 'Saving records...');
      }
    }
    if (batchCount > 0) {
      await batch.commit();
      onProgress?.call(processed, validTotal, 'Saving records...');
    }

    // Step 4: Delete plates from this source that are no longer in file
    final toDelete = existingPlates.entries
        .where((e) => !uploadedPlates.containsKey(e.key))
        .toList();

    if (toDelete.isNotEmpty) {
      onProgress?.call(
        processed, validTotal,
        'Removing ${toDelete.length} settled accounts...',
      );
      WriteBatch delBatch = _db.batch();
      int delCount = 0;
      for (final e in toDelete) {
        delBatch.delete(_db.collection(_vehiclesCol).doc(e.value));
        delCount++;
        deleted++;
        if (delCount >= batchSize) {
          await delBatch.commit();
          delBatch = _db.batch();
          delCount = 0;
        }
      }
      if (delCount > 0) await delBatch.commit();
    }

    // Step 5: Save source name for future dropdown
    await saveSource(sourceName);

    return UploadResult(
      added: added, updated: updated, deleted: deleted,
      skipped: skipped, total: total,
      skippedPlates: skippedPlates,
    );
  }

  // ── SCAN RECORDS ───────────────────────────

  /// Save a plate scan record with optional cropped image
  Future<void> saveScanRecord(Map<String, dynamic> data) async {
    try {
      await _db.collection(_scansCol).add({
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error saving scan record: $e');
    }
  }

  /// Get recent scan records
  Future<List<Map<String, dynamic>>> getRecentScans({int limit = 50}) async {
    try {
      final snap = await _db
          .collection(_scansCol)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      
      return snap.docs.map((doc) => {
        ...doc.data(),
        'id': doc.id,
      }).toList();
    } catch (e) {
      print('Error getting recent scans: $e');
      return [];
    }
  }
  /// Get all unique plate numbers in the system for fuzzy matching / cached scan assistance.
  Future<Set<String>> getAllUniquePlates() async {
    try {
      final snap = await _db.collection(_vehiclesCol).get(); 
      final plates = <String>{};
      for (final doc in snap.docs) {
        final lastUnderscore = doc.id.lastIndexOf('_');
        if (lastUnderscore >= 0) {
          plates.add(doc.id.substring(0, lastUnderscore).toUpperCase());
        }
      }
      return plates;
    } catch (e) {
      print('Error fetching plates for fuzzy match: $e');
      return {};
    }
  }
}
