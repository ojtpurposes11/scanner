import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/auth_service.dart';
import '../services/excel_parser_service.dart';
import '../services/firestore_service.dart';
import '../models/vehicle_model.dart';
import '../widgets/search_widget.dart';
import '../widgets/vehicle_result_popup.dart';
import 'camera_scanner_export.dart';
import 'entry_screen.dart';
import '../widgets/info_dialog.dart';
import '../widgets/credits_dialog.dart';

enum UploadState { idle, picking, parsing, preview, writing, done, error }

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final _authService = AuthService();
  final _excelParser = ExcelParserService();
  final _firestoreService = FirestoreService();

  // 0 = dashboard home, 1 = upload screen
  int _tab = 0;

  // Upload state
  UploadState _uploadState = UploadState.idle;
  String _statusMessage = '';
  String? _errorMessage;
  double _progress = 0.0;
  int _progressCurrent = 0;
  int _progressTotal = 0;
  UploadResult? _lastResult;
  List<Map<String, dynamic>> _parsedRows = [];
  String _pendingFileName = '';
  String _detectedAgency  = '';   // auto-detected from Agency column

  // ── Upload flow ──────────────────────────────────────────────

  Future<void> _pickAndProcess() async {
    setState(() {
      _uploadState = UploadState.picking;
      _errorMessage = null;
      _lastResult = null;
      _progress = 0;
    });

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        allowMultiple: false,
        withData: true,
      );
    } catch (e) {
      _setError('Could not open file picker: $e');
      return;
    }

    if (result == null || result.files.isEmpty) {
      setState(() => _uploadState = UploadState.idle);
      return;
    }

    final pickedFile = result.files.first;
    _pendingFileName = pickedFile.name;
    final bytes = pickedFile.bytes;

    if (bytes == null) {
      _setError('Could not read file. Please try again.');
      return;
    }

    setState(() {
      _uploadState = UploadState.parsing;
      _statusMessage = 'Reading "$_pendingFileName"...';
    });

    List<Map<String, dynamic>> rows;
    try {
      rows = await _excelParser.parseBytes(bytes);
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      return;
    }

    // ── Auto-detect agency ─────────────────────────────────────
    // Priority 1: read from the Agency column in the file contents.
    // Priority 2: extract from the file name (e.g. "BDO_Accounts.xlsx"
    //             → "BDO", "EastWest_Accounts.xlsx" → "EastWest").
    // If neither works, show a clear error.
    String agency = rows
        .map((r) => (r['Agency'] ?? '').toString().trim())
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');

    if (agency.isEmpty) {
      // Fallback: strip extension then take everything before the
      // first underscore or space (handles "BDO_Accounts", "PSB", etc.)
      final nameNoExt = _pendingFileName
          .replaceAll(RegExp(r'\.[^.]+$'), ''); // drop .xlsx / .xls
      final firstPart = nameNoExt.split(RegExp(r'[_\s]+')).first.trim();
      if (firstPart.isNotEmpty) {
        agency = firstPart;
      }
    }

    if (agency.isEmpty) {
      _setError(
        'Could not detect the bank/agency.\n\n'
        'Either fill in the "Agency" column in the file, '
        'or rename the file starting with the bank name '
        '(e.g. "BDO_Accounts.xlsx").',
      );
      return;
    }

    setState(() {
      _parsedRows      = rows;
      _detectedAgency  = agency;
      _uploadState     = UploadState.preview;
    });
  }

  Future<void> _confirmUpload() async {
    setState(() {
      _uploadState = UploadState.writing;
      _progressTotal = _parsedRows.length;
      _progressCurrent = 0;
      _progress = 0;
      _statusMessage = 'Saving records...';
    });

    UploadResult uploadResult;
    try {
      uploadResult = await _firestoreService.syncVehicles(
        _parsedRows,
        _detectedAgency,
        onProgress: (done, total, stage) {
          if (mounted) {
            setState(() {
              _progressCurrent = done;
              _progressTotal = total;
              _progress = total > 0 ? done / total : 0;
              _statusMessage = '$stage ($done / $total)';
            });
          }
        },
      );
    } catch (e) {
      _setError('Upload failed: $e\n\nCheck your internet connection and try again.');
      return;
    }

    setState(() {
      _uploadState = UploadState.done;
      _lastResult = uploadResult;
      _progress = 1.0;
    });
  }

  void _setError(String message) =>
      setState(() { _uploadState = UploadState.error; _errorMessage = message; });

  void _resetUpload() {
    setState(() {
      _uploadState    = UploadState.idle;
      _errorMessage   = null;
      _lastResult     = null;
      _parsedRows     = [];
      _pendingFileName = '';
      _detectedAgency = '';
      _progress       = 0;
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.red[700],
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
    ));
  }

  void _logout() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _authService.signOut();
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const EntryScreen()),
                  (_) => false,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

  // ── Search sheet helpers ──────────────────────────────────────

  void _openVoiceSearch() {
    _showSearchSheet(mode: SearchMode.voice);
  }

  void _openManualSearch() {
    _showSearchSheet(mode: SearchMode.manual);
  }

  void _showSearchSheet({SearchMode mode = SearchMode.manual}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, __) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SearchWidget(
                initialMode: mode,
                onScanCamera: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(
                      builder: (_) => const CameraScannerScreen()));
                },
                onResult: (vehicles, plate) {
                  Navigator.pop(context);
                  _showResult(vehicles, plate, mode);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showResult(List<VehicleModel> vehicles, String plate, SearchMode mode) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: vehicles.isNotEmpty ? 0.88 : 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, __) => VehicleResultPopup(
          vehicles: vehicles,
          searchedPlate: plate,
          searchMode: mode,
          onScanAnother: () {
            Navigator.pop(context);
            if (mode == SearchMode.camera) {
              Navigator.push(context, MaterialPageRoute(
                  builder: (_) => const CameraScannerScreen()));
            } else {
              _showSearchSheet(mode: mode);
            }
          },
          onTypeSearchAnother: () {
            Navigator.pop(context);
            _showSearchSheet(mode: SearchMode.manual);
          },
          onScanAgain: () {
            Navigator.pop(context);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const CameraScannerScreen()));
          },
          onBackToDashboard: () => Navigator.pop(context),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _logout();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: Stack(
        children: [
          // ── Background image ──
          Positioned.fill(
            child: Image.asset(
              'assets/splash_bg.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),
          ),
          // ── Subtle white overlay so content stays readable ──
          Positioned.fill(
            child: Container(
              color: Colors.white.withOpacity(0.82),
            ),
          ),
          // ── Content ──
          SafeArea(
            child: _tab == 0 ? _buildDashboard() : _buildUploadScreen(),
          ),
        ],
      ),
    ),
    );
  }

  // ── Dashboard home ─────────────────────────────────────────────

  Widget _buildDashboard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTopBar(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel(label: 'Search Vehicle'),
                const SizedBox(height: 12),

                // Three search cards — FULL WIDTH stacked, same width as upload
                _DashCard(
                  icon: Icons.camera_alt_outlined,
                  label: 'Camera Scan',
                  subtitle: 'Scan a plate using your camera',
                  filled: true,
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CameraScannerScreen())),
                ),
                const SizedBox(height: 12),
                _DashCard(
                  icon: Icons.mic_none_rounded,
                  label: 'Voice Search',
                  subtitle: 'Search by speaking the plate number',
                  filled: false,
                  onTap: _openVoiceSearch,
                ),
                const SizedBox(height: 12),
                _DashCard(
                  icon: Icons.search_rounded,
                  label: 'Type Search',
                  subtitle: 'Manually type the plate number',
                  filled: true,
                  onTap: _openManualSearch,
                ),
                const SizedBox(height: 28),

                // Admin Tools — Upload Database
                const _SectionLabel(label: 'Admin Tools'),
                const SizedBox(height: 12),
                _DashCard(
                  icon: Icons.upload_rounded,
                  label: 'Upload Database',
                  subtitle: 'Import vehicle records from Excel',
                  filled: false,
                  onTap: () => setState(() => _tab = 1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (_) => const CreditsDialog(),
    );
  }

  void _showHowToDialog() {
    showDialog(
      context: context,
      builder: (_) => const InfoDialog(),
    );
  }


  Widget _buildTopBar() {
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12 ? 'Good Morning' : hour < 17 ? 'Good Afternoon' : 'Good Evening';
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    final dateStr = '${days[now.weekday % 7]}, ${months[now.month - 1]} ${now.day}, ${now.year}';

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFCC0000), Color(0xFFFF2222)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row — icon + title + actions
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.admin_panel_settings_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 10),
              const Text('Admin Dashboard',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
              const Spacer(),
              GestureDetector(
                onTap: _showAboutDialog,
                child: Icon(Icons.info_outline_rounded,
                    size: 22, color: Colors.white.withValues(alpha: 0.85)),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: _showHowToDialog,
                child: Icon(Icons.help_outline_rounded,
                    size: 22, color: Colors.white.withValues(alpha: 0.85)),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: _logout,
                child: Icon(Icons.logout_rounded,
                    size: 22, color: Colors.white.withValues(alpha: 0.85)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Greeting + date row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(greeting + ', Admin!',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(Icons.calendar_today_rounded,
                          size: 12, color: Colors.white.withValues(alpha: 0.7)),
                      const SizedBox(width: 5),
                      Text(dateStr,
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.75))),
                    ],
                  ),
                ],
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  // ── Upload screen ──────────────────────────────────────────────

  Widget _buildUploadScreen() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top bar with back
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              GestureDetector(
                onTap: () { _resetUpload(); setState(() => _tab = 0); },
                child: const Icon(Icons.arrow_back_ios_rounded,
                    size: 18, color: Color(0xFF1A1A1A)),
              ),
              const SizedBox(width: 10),
              const Text('Upload Database',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A))),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _buildUploadBody(),
          ),
        ),
      ],
    );
  }

  Widget _buildUploadBody() {
    switch (_uploadState) {
      case UploadState.idle:      return _buildIdleUpload();
      case UploadState.picking:
      case UploadState.parsing:
        return _buildSpinner(_statusMessage.isNotEmpty
            ? _statusMessage : 'Opening file picker...');
      case UploadState.preview:   return _buildPreviewStep();
      case UploadState.writing:   return _buildWritingStep();
      case UploadState.done:      return _buildDoneStep();
      case UploadState.error:     return _buildErrorStep();
    }
  }

  Widget _buildIdleUpload() {
    return Column(
      children: [
        const SizedBox(height: 8),
        // Dashed tap-to-select box
        GestureDetector(
          onTap: _pickAndProcess,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey[300]!, width: 1.5),
            ),
            child: Column(
              children: [
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(
                      color: Colors.red[50], shape: BoxShape.circle),
                  child: const Icon(Icons.insert_drive_file_outlined,
                      color: Color(0xFFFF0000), size: 28),
                ),
                const SizedBox(height: 16),
                const Text('Tap to select database file',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A))),
                const SizedBox(height: 6),
                Text('Supports .xlsx and .xls formats',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                const SizedBox(height: 4),
                Text(
                  'Reads any bank format (PLATE #, ACCT NAME,\nUNIT DESCRIPTION, etc.)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _pickAndProcess,
            icon: const Icon(Icons.upload_rounded, color: Colors.white, size: 20),
            label: const Text('Select File',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Uploaded data is saved to the cloud and available on all devices instantly.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
      ],
    );
  }

  Widget _buildSpinner(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(
          children: [
            const CircularProgressIndicator(
                color: Color(0xFFFF0000), strokeWidth: 3),
            const SizedBox(height: 20),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }


  Widget _buildPreviewStep() {
    final validCount = _parsedRows
        .where((r) => FirestoreService.isValidPlate(
            (r['Plate #'] ?? '').toString().trim().toUpperCase()))
        .length;
    final invalidCount = _parsedRows.length - validCount;

    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                    color: Colors.blue[50], shape: BoxShape.circle),
                child: Icon(Icons.preview_rounded,
                    color: Colors.blue[600], size: 28),
              ),
              const SizedBox(height: 14),
              const Text('Ready to Upload',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.account_balance_rounded, size: 14, color: Colors.red[700]),
                    const SizedBox(width: 6),
                    Text('Bank: $_detectedAgency',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.red[700])),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text('"$_pendingFileName"',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10, runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _StatPill(label: 'Valid', value: '$validCount', color: Colors.green),
                  if (invalidCount > 0)
                    _StatPill(label: 'Invalid', value: '$invalidCount', color: Colors.orange),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.orange[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange[200]!),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.orange[700], size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$_detectedAgency accounts in the database that are NOT in this file will be automatically removed (settled/paid accounts).',
                  style: TextStyle(
                      fontSize: 12, color: Colors.orange[800], height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: OutlinedButton(
              onPressed: _resetUpload,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey[600],
                side: BorderSide(color: Colors.grey[300]!),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30)),
              ),
              child: const Text('Back'),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton.icon(
              onPressed: _confirmUpload,
              icon: const Icon(Icons.cloud_upload_rounded,
                  color: Colors.white, size: 18),
              label: const Text('Upload',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0000),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30)),
              ),
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildWritingStep() {
    final pct = (_progress * 100).toStringAsFixed(0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            const Icon(Icons.cloud_upload_rounded,
                color: Color(0xFFFF0000), size: 40),
            const SizedBox(height: 16),
            const Text('Saving to database...',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('$_progressCurrent of $_progressTotal  •  $pct%',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 4),
            Text(_statusMessage,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                color: const Color(0xFFFF0000),
                backgroundColor: Colors.red[100],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDoneStep() {
    final r = _lastResult!;
    return Column(
      children: [
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                    color: Colors.green[50], shape: BoxShape.circle),
                child: Icon(Icons.check_circle_rounded,
                    color: Colors.green[600], size: 30),
              ),
              const SizedBox(height: 14),
              const Text('Upload Complete!',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Bank: $_detectedAgency',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8, runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _StatPill(label: 'Added', value: '${r.added}', color: Colors.green),
                  _StatPill(label: 'Updated', value: '${r.updated}', color: Colors.blue),
                  if (r.deleted > 0)
                    _StatPill(label: 'Settled', value: '${r.deleted}', color: Colors.orange),
                  if (r.skipped > 0)
                    _StatPill(label: 'Skipped', value: '${r.skipped}', color: Colors.grey),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _resetUpload,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30)),
            ),
            child: const Text('Upload Another File',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () { _resetUpload(); setState(() => _tab = 0); },
          child: const Text('Back to Dashboard',
              style: TextStyle(
                  fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }

  Widget _buildErrorStep() {
    return Column(
      children: [
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.red[200]!),
          ),
          child: Column(
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.red[400], size: 40),
              const SizedBox(height: 12),
              const Text('Upload Failed',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: Colors.red)),
              const SizedBox(height: 10),
              Text(
                _errorMessage ?? 'Unknown error occurred.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.red[700], height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _resetUpload,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
            label: const Text('Try Again',
                style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30)),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Shared widgets (used by both dashboards)
// ══════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey));
  }
}

/// Full-width horizontal card for dashboard actions.
/// Matches the upload card width — all cards are equal.
class _DashCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool filled;
  final VoidCallback onTap;

  const _DashCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.filled,
    required this.onTap,
  });

  @override
  State<_DashCard> createState() => _DashCardState();
}

class _DashCardState extends State<_DashCard> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Hover/press lightens filled cards, darkens outlined cards
    final bool active = _pressed || _hovered;

    final Color bgColor = widget.filled
        ? active ? const Color(0xFFCC0000) : const Color(0xFFFF0000)
        : active ? const Color(0xFFFFF0F0) : Colors.white;

    final Color iconCircleBg = widget.filled
        ? Colors.white.withValues(alpha: active ? 0.35 : 0.22)
        : active ? Colors.red[100]! : Colors.red[50]!;

    final Color iconColor = widget.filled
        ? Colors.white
        : const Color(0xFFFF0000);

    final Color titleColor = widget.filled
        ? Colors.white
        : const Color(0xFFFF0000);

    final Color subtitleColor = widget.filled
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.grey[500]!;

    final double elevation = active ? 2 : widget.filled ? 8 : 2;
    final double scale = _pressed ? 0.97 : _hovered ? 1.02 : 1.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(18),
              border: widget.filled
                  ? null
                  : Border.all(
                      color: active
                          ? const Color(0xFFFF0000)
                          : const Color(0xFFFF0000).withValues(alpha: 0.6),
                      width: active ? 2 : 1.5),
              boxShadow: widget.filled
                  ? [BoxShadow(
                      color: const Color(0xFFFF0000)
                          .withValues(alpha: active ? 0.30 : 0.18),
                      blurRadius: active ? 24 : 14,
                      offset: Offset(0, active ? 8 : 5),
                    )]
                  : [BoxShadow(
                      color: Colors.black
                          .withValues(alpha: active ? 0.08 : 0.04),
                      blurRadius: active ? 14 : 6,
                      offset: Offset(0, active ? 4 : 2),
                    )],
            ),
            child: Row(
              children: [
                // Icon with animated background
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 60, height: 60,
                  decoration: BoxDecoration(
                    color: iconCircleBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, color: iconColor, size: 28),
                ),
                const SizedBox(width: 20),
                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.label,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: titleColor)),
                      const SizedBox(height: 4),
                      Text(widget.subtitle,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: subtitleColor,
                              height: 1.4)),
                    ],
                  ),
                ),
                // Arrow indicator
                AnimatedOpacity(
                  opacity: active ? 1.0 : 0.4,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: widget.filled ? Colors.white : const Color(0xFFFF0000),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  final MaterialColor color;

  const _StatPill({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color[50],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color[200]!),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w900, color: color[700])),
          Text(label,
              style: TextStyle(fontSize: 11, color: color[600])),
        ],
      ),
    );
  }
}