import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class ExcelParserService {
  // ── Vehicle ID Detection Logic ─────────────────────────────────────────
  //
  // PRIORITY ORDER:
  //   1. Column with "plate" in header     → accepts 6–7 char alphanumeric
  //   2. Column with "conduction" in header → accepts 6–10 char alphanumeric
  //   3. No dedicated column (fallback scan left-to-right):
  //        - 6–7 char alphanumeric          → plate number
  //        - 8 char starting with "CS"      → conduction sticker
  //
  // All vehicle IDs are stored under the key "Plate #" for consistency.
  // ───────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> parseBytes(Uint8List bytes) async {
    // ── Decode xlsx as ZIP ──
    final archive = ZipDecoder().decodeBytes(bytes);

    // ── Extract shared strings ──
    final sharedStrings = <String>[];
    final ssFile = archive.findFile('xl/sharedStrings.xml');
    if (ssFile != null) {
      final ssXml = XmlDocument.parse(
          String.fromCharCodes(ssFile.content as List<int>));
      for (final si in ssXml.findAllElements('si')) {
        final text =
            si.findAllElements('t').map((t) => t.innerText).join();
        sharedStrings.add(text);
      }
    }

    // ── Find first sheet ──
    ArchiveFile? sheetFile;
    for (final name in [
      'xl/worksheets/sheet1.xml',
      'xl/worksheets/Sheet1.xml',
    ]) {
      sheetFile = archive.findFile(name);
      if (sheetFile != null) break;
    }
    sheetFile ??= archive.files.firstWhere(
      (f) =>
          f.name.startsWith('xl/worksheets/sheet') &&
          f.name.endsWith('.xml'),
      orElse: () =>
          throw Exception('No worksheet found. Please check the file.'),
    );

    final sheetXml = XmlDocument.parse(
        String.fromCharCodes(sheetFile!.content as List<int>));
    final rows = sheetXml.findAllElements('row').toList();
    if (rows.isEmpty) throw Exception('The file appears to be empty.');

    // ── Helper: column letter ref → index (e.g. "C3" → 2) ──
    int colIndexFromRef(String ref) {
      final letters = ref.replaceAll(RegExp(r'[0-9]'), '');
      int col = 0;
      for (final ch in letters.codeUnits) {
        col = col * 26 + (ch - 'A'.codeUnitAt(0) + 1);
      }
      return col - 1;
    }

    // ── Helper: get cell string value ──
    String getCellValue(XmlElement cell) {
      final type = cell.getAttribute('t');
      final vEls = cell.findElements('v');
      if (vEls.isEmpty) return '';
      final raw = vEls.first.innerText.trim();

      if (type == 's') {
        final idx = int.tryParse(raw);
        if (idx != null && idx < sharedStrings.length) {
          return sharedStrings[idx].trim();
        }
        return raw;
      }
      if (type == 'inlineStr') {
        return cell
            .findAllElements('t')
            .map((t) => t.innerText)
            .join()
            .trim();
      }
      // Number — strip trailing .0 for whole numbers
      final d = double.tryParse(raw);
      if (d != null && d == d.truncateToDouble()) {
        return d.toInt().toString();
      }
      return raw;
    }

    // ── Helper: parse a row into col-index → value map ──
    Map<int, String> parseRow(XmlElement row) {
      final map = <int, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        if (ref.isEmpty) continue;
        final val = getCellValue(cell);
        if (val.isNotEmpty) map[colIndexFromRef(ref)] = val;
      }
      return map;
    }

    // ── Step 1: Read header row ──
    final headerMap = parseRow(rows.first);
    if (headerMap.isEmpty) {
      throw Exception(
          'First row appears empty. The first row must contain column headers.');
    }

    // ── Step 1b: Sanity check — reject files with no vehicle-related headers ──
    // Required: at least one of these must appear (case-insensitive).
    // This prevents random Excel files (test sheets, reports, etc.) from
    // being silently parsed and uploading garbage records.
    const _knownHeaders = [
      'plate', 'conduction', 'acct', 'account', 'agency',
      'unit', 'status', 'area', 'location', 'endo',
    ];
    final headerValues = headerMap.values.map((h) => h.toLowerCase()).toList();
    final hasKnownHeader = _knownHeaders.any(
      (kw) => headerValues.any((h) => h.contains(kw)),
    );
    if (!hasKnownHeader) {
      throw Exception(
        'This file does not appear to be a vehicle database.\n\n'
        'No recognizable columns were found (e.g. Plate #, Agency, '
        'Acct. Name, Status, Area).\n\n'
        'Please upload the correct vehicle records file.',
      );
    }

    // ── Step 2: Identify dedicated vehicle ID columns ──
    // plateColIndex     → column with "plate" in header
    // conductionColIndex → column with "conduction" in header
    int? plateColIndex;
    int? conductionColIndex;

    headerMap.forEach((colIdx, header) {
      final lower = header.toLowerCase();
      if (lower.contains('plate')) {
        plateColIndex = colIdx;
      } else if (lower.contains('conduction')) {
        conductionColIndex = colIdx;
      }
    });

    // ── Step 3: Validators ──

    // Plate: 6–7 alphanumeric, MUST contain at least one digit AND one letter.
    // Pure-letter words (PENDING, STATUS, PASS, FAILED, etc.) are rejected.
    // Pure-digit strings are also rejected.
    bool isValidPlate(String value) {
      final c = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      return c.length >= 6 &&
          c.length <= 7 &&
          RegExp(r'^[A-Z0-9]{6,7}$').hasMatch(c) &&
          RegExp(r'[A-Z]').hasMatch(c) &&   // must have at least one letter
          RegExp(r'[0-9]').hasMatch(c);     // must have at least one digit
    }

    // Conduction sticker from dedicated column: 6–10 alphanumeric
    bool isValidConduction(String value) {
      final c = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      return c.length >= 6 &&
          c.length <= 10 &&
          RegExp(r'^[A-Z0-9]{6,10}$').hasMatch(c);
    }

    String cleanId(String value) =>
        value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

    // ── Step 4: Parse data rows ──
    final result = <Map<String, dynamic>>[];

    for (int i = 1; i < rows.length; i++) {
      final rowMap = parseRow(rows[i]);
      if (rowMap.isEmpty) continue;

      String? vehicleId;

      // ── STRATEGY 1: Dedicated plate column ──
      if (plateColIndex != null) {
        final raw = rowMap[plateColIndex!] ?? '';
        final cleaned = cleanId(raw);
        if (isValidPlate(cleaned)) {
          vehicleId = cleaned;
        }
      }
      // ── STRATEGY 2: Dedicated conduction column ──
      else if (conductionColIndex != null) {
        final raw = rowMap[conductionColIndex!] ?? '';
        final cleaned = cleanId(raw);
        if (isValidConduction(cleaned)) {
          vehicleId = cleaned;
        }
      }
      // ── STRATEGY 3: Fallback — scan all cells ──
      // In fallback, conduction stickers (2 letters + 4 digits) look identical
      // to 6-char plates, so we treat all 6–7 char values the same way.
      else {
        for (final entry in rowMap.entries) {
          final cleaned = cleanId(entry.value);
          if (isValidPlate(cleaned)) {
            vehicleId = cleaned;
            break;
          }
        }
      }

      if (vehicleId == null) continue;

      // Build record using actual header names
      final record = <String, dynamic>{
        'Plate #': vehicleId,
      };

      rowMap.forEach((colIdx, cellValue) {
        final header = headerMap[colIdx];
        if (header == null || header.isEmpty) return;

        // Skip the source column itself
        if (colIdx == plateColIndex || colIdx == conductionColIndex) return;

        // In fallback mode, skip the cell that was the vehicle ID
        if (plateColIndex == null && conductionColIndex == null) {
          if (cleanId(cellValue) == vehicleId) return;
        }

        record[header] = cellValue;
      });

      result.add(record);
    }

    if (result.isEmpty) {
      String hint;
      if (plateColIndex != null) {
        hint =
            'No valid plate numbers found in the "${headerMap[plateColIndex!]}" column.\n\n'
            'Plate numbers must be 6–7 alphanumeric characters (e.g. ABC123 or ABC1234).';
      } else if (conductionColIndex != null) {
        hint =
            'No valid conduction sticker numbers found in the "${headerMap[conductionColIndex!]}" column.\n\n'
            'Conduction stickers must be 6–10 alphanumeric characters.';
      } else {
        hint =
            'No valid plate numbers or conduction stickers found in this file.\n\n'
            '• Plate numbers: 6–7 alphanumeric characters (e.g. ABC123, ABC1234)\n'
            '• Conduction stickers: starts with "CS" + 6 characters (e.g. CS123456)';
      }
      throw Exception(hint);
    }

    return result;
  }
}