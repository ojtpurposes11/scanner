import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../models/vehicle_model.dart';

// Search mode controls the label of the primary action button in results.
enum SearchMode { camera, voice, manual }

const List<String> _kMoneyKeywords = [
  'balance', 'amount', 'outstanding', 'payment', 'loan',
  'principal', 'interest', 'penalty', 'fee', 'receivable',
  'payable', 'price', 'cost', 'charge', 'value',
];

// Fields to group under LOCATION section
const List<String> _kLocationKeys = [
  'area', 'location', 'region', 'address', 'primary address',
  'secondary address', 'sub-area', 'geo team', 'a2',
];

// Fields to group under VEHICLE DETAILS section
const List<String> _kVehicleKeys = [
  'unit description', 'model', 'vehicle', 'vehicle description',
  'color', 'serial #', 'serial number', 'chassis no', 'chassis series',
  'engine #', 'engine number', 'engine series',
];

// Fields to group under ACCOUNT section
const List<String> _kAccountKeys = [
  'acct number', 'account number', 'account no', 'account ref',
  'acct. number', 'loan balance', 'balance', 'outstanding balance',
  'days past due', 'overdue days', 'days overdue', 'daysoverdue',
  'bucket', 'status', 'saturation level', 'priority level', 'risk level',
  'endo date', 'maturity date', 'pullout date',
];

class VehicleResultPopup extends StatefulWidget {
  final List<VehicleModel> vehicles;
  final String searchedPlate;
  final VoidCallback onScanAnother;
  final VoidCallback onBackToDashboard;
  final VoidCallback onTypeSearchAnother;
  final VoidCallback onScanAgain;
  // Controls primary action button label & icon
  final SearchMode searchMode;

  const VehicleResultPopup({
    super.key,
    required this.vehicles,
    required this.searchedPlate,
    required this.onScanAnother,
    required this.onBackToDashboard,
    required this.onTypeSearchAnother,
    required this.onScanAgain,
    this.searchMode = SearchMode.camera,
  });

  @override
  State<VehicleResultPopup> createState() => _VehicleResultPopupState();
}

class _VehicleResultPopupState extends State<VehicleResultPopup>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    if (widget.vehicles.length > 1) {
      _tabController = TabController(
          length: widget.vehicles.length, vsync: this);
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title bar
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const Text('Search Result',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A))),
                const Spacer(),
                GestureDetector(
                  onTap: widget.onBackToDashboard,
                  child: const Icon(Icons.close_rounded,
                      size: 22, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Flexible(
            child: widget.vehicles.isEmpty
                ? _buildNotFound()
                : widget.vehicles.length == 1
                    ? _buildSingleResult(widget.vehicles.first)
                    : _buildMultiResult(),
          ),
        ],
      ),
    );
  }

  // ── Not found ──
  Widget _buildNotFound() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
                color: Colors.grey[100], shape: BoxShape.circle),
            child: Icon(Icons.search_off_rounded,
                size: 32, color: Colors.grey[400]),
          ),
          const SizedBox(height: 12),
          Text(
            widget.searchedPlate,
            style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
                color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 6),
          Text('No record found for this plate number.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[500])),
          const SizedBox(height: 20),
          _buildButtons(notFound: true),
        ],
      ),
    );
  }

  // ── Single result ──
  Widget _buildSingleResult(VehicleModel v) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlateHeader(plate: v.plateNumber, source: v.source),
          const SizedBox(height: 16),
          ..._buildSections(v),
          const SizedBox(height: 20),
          _buildButtons(),
        ],
      ),
    );
  }

  // ── Multi result (tabs) ──
  Widget _buildMultiResult() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Plate number
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: _PlateHeader(
            plate: widget.searchedPlate,
            source: '${widget.vehicles.length} sources',
          ),
        ),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: const Color(0xFFFF0000),
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFFFF0000),
          labelStyle: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700),
          tabs: widget.vehicles
              .map((v) => Tab(
                  text: v.source.isNotEmpty ? v.source : 'Unknown'))
              .toList(),
        ),
        const Divider(height: 1),
        Flexible(
          child: TabBarView(
            controller: _tabController,
            children: widget.vehicles.map((v) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ..._buildSections(v),
                    const SizedBox(height: 20),
                    _buildButtons(),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── Build categorised sections ──
  List<Widget> _buildSections(VehicleModel v) {
    final locationFields = <MapEntry<String, String>>[];
    final vehicleFields = <MapEntry<String, String>>[];
    final accountFields = <MapEntry<String, String>>[];
    final otherFields = <MapEntry<String, String>>[];

    for (final e in v.displayFields) {
      final key = e.key.toLowerCase();
      if (_kLocationKeys.any((k) => key.contains(k))) {
        locationFields.add(e);
      } else if (_kVehicleKeys.any((k) => key.contains(k))) {
        vehicleFields.add(e);
      } else if (_kAccountKeys.any((k) => key.contains(k))) {
        accountFields.add(e);
      } else {
        otherFields.add(e);
      }
    }

    final sections = <Widget>[];

    if (locationFields.isNotEmpty) {
      sections.add(_Section(
        title: 'LOCATION',
        titleColor: const Color(0xFFFF0000),
        fields: locationFields,
      ));
      sections.add(const SizedBox(height: 12));
    }
    if (vehicleFields.isNotEmpty) {
      sections.add(_Section(
        title: 'VEHICLE DETAILS',
        titleColor: const Color(0xFFFF0000),
        fields: vehicleFields,
      ));
      sections.add(const SizedBox(height: 12));
    }
    if (accountFields.isNotEmpty) {
      sections.add(_Section(
        title: 'ACCOUNT',
        titleColor: const Color(0xFFFF0000),
        fields: accountFields,
      ));
      sections.add(const SizedBox(height: 12));
    }
    if (otherFields.isNotEmpty) {
      sections.add(_Section(
        title: 'OTHER INFO',
        titleColor: const Color(0xFFFF0000),
        fields: otherFields,
      ));
      sections.add(const SizedBox(height: 12));
    }

    if (sections.isEmpty) {
      sections.add(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text('No additional information stored.',
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          ),
        ),
      );
    }

    return sections;
  }

  Widget _buildButtons({bool notFound = false}) {
    // Per-mode config — label + icon + callback matches how the user arrived
    final String actionLabel;
    final IconData actionIcon;
    final VoidCallback actionCallback;

    switch (widget.searchMode) {
      case SearchMode.camera:
        actionLabel = 'Scan Again';
        actionIcon = Icons.document_scanner_rounded;
        actionCallback = widget.onScanAnother;
        break;
      case SearchMode.voice:
        actionLabel = 'Audio Search Again';
        actionIcon = Icons.mic_rounded;
        actionCallback = widget.onScanAnother;
        break;
      case SearchMode.manual:
        actionLabel = 'Type Search Again';
        actionIcon = Icons.keyboard_rounded;
        actionCallback = widget.onScanAnother;
        break;
    }

    return Column(
      children: [
        // ── Primary: mode-matched repeat button ──
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: actionCallback,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0000),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(actionIcon, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Text(actionLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        // ── Back to Dashboard text link ──
        GestureDetector(
          onTap: widget.onBackToDashboard,
          child: const Text(
            'Back to Dashboard',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Plate header ────────────────────────────────────────────────

// ── Bank theme definition ──────────────────────────────────────────────────
class _BankTheme {
  final Color primary;      // main background color
  final Color secondary;    // gradient end / accent
  final Color textColor;    // bank name text
  final String displayName; // shown in header
  final String abbrev;      // short badge (2-4 chars)

  const _BankTheme({
    required this.primary,
    required this.secondary,
    required this.textColor,
    required this.displayName,
    required this.abbrev,
  });
}

// ── Known Philippine bank themes (actual brand colors) ─────────────────────
// Fallback is used for any agency not listed here.
const _kDefaultTheme = _BankTheme(
  primary:     Color(0xFFCC0000),
  secondary:   Color(0xFF990000),
  textColor:   Colors.white,
  displayName: 'Convergent',
  abbrev:      'CVG',
);

const Map<String, _BankTheme> _kBankThemes = {
  // ── TFS (Toyota Financial Services) — red ────────────────────────────
  'tfs': _BankTheme(
    primary:     Color(0xFFEB0A1E),
    secondary:   Color(0xFFB30000),
    textColor:   Colors.white,
    displayName: 'Toyota Financial Services',
    abbrev:      'TFS',
  ),
  'toyota': _BankTheme(
    primary:     Color(0xFFEB0A1E),
    secondary:   Color(0xFFB30000),
    textColor:   Colors.white,
    displayName: 'Toyota Financial Services',
    abbrev:      'TFS',
  ),
  // ── CBS (China Bank Savings) — blue & orange ─────────────────────────
  'cbs': _BankTheme(
    primary:     Color(0xFF0054A6),
    secondary:   Color(0xFFF7941D),
    textColor:   Colors.white,
    displayName: 'China Bank Savings',
    abbrev:      'CBS',
  ),
  'chinabank savings': _BankTheme(
    primary:     Color(0xFF0054A6),
    secondary:   Color(0xFFF7941D),
    textColor:   Colors.white,
    displayName: 'China Bank Savings',
    abbrev:      'CBS',
  ),
  // ── PSBANK — blue ───────────────────────────────────────────
  'psbank': _BankTheme(
    primary:     Color(0xFF0057A8),
    secondary:   Color(0xFF0073D1),
    textColor:   Colors.white,
    displayName: 'Philippine Savings Bank',
    abbrev:      'PSB',
  ),
  'psb': _BankTheme(
    primary:     Color(0xFF0057A8),
    secondary:   Color(0xFF0073D1),
    textColor:   Colors.white,
    displayName: 'Philippine Savings Bank',
    abbrev:      'PSB',
  ),
  // ── JACCS — red & blue ───────────────────────────────────────
  'jaccs': _BankTheme(
    primary:     Color(0xFFE4002B),
    secondary:   Color(0xFF0033A0),
    textColor:   Colors.white,
    displayName: 'JACCS Finance',
    abbrev:      'JAC',
  ),
  // ── ORICO — blue ────────────────────────────────────────────
  'orico': _BankTheme(
    primary:     Color(0xFF004DA0),
    secondary:   Color(0xFF003366),
    textColor:   Colors.white,
    displayName: 'Orico Auto Finance',
    abbrev:      'ORI',
  ),
  // ── RCBC — green ────────────────────────────────────────────
  'rcbc': _BankTheme(
    primary:     Color(0xFF006838),
    secondary:   Color(0xFF009A52),
    textColor:   Colors.white,
    displayName: 'RCBC',
    abbrev:      'RCBC',
  ),
};

/// Resolve the theme for any agency string.
/// Tries exact match first, then partial match, then returns default.
_BankTheme _resolveTheme(String agency) {
  if (agency.isEmpty) return _kDefaultTheme;
  final key = agency.toLowerCase().trim();
  // Exact match
  if (_kBankThemes.containsKey(key)) return _kBankThemes[key]!;
  // Partial match — agency string contains a known key or vice versa
  for (final entry in _kBankThemes.entries) {
    if (key.contains(entry.key) || entry.key.contains(key)) {
      return entry.value;
    }
  }
  return _kDefaultTheme;
}

// ── Plate header with bank branding ────────────────────────────────────────
class _PlateHeader extends StatelessWidget {
  final String plate;
  final String source; // agency name from vehicle record

  const _PlateHeader({required this.plate, required this.source});

  @override
  Widget build(BuildContext context) {
    final theme = _resolveTheme(source);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [theme.primary, theme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          // ── Bank name bar ──────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.18),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                // Abbreviation badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    theme.abbrev,
                    style: TextStyle(
                      color: theme.textColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    theme.displayName,
                    style: TextStyle(
                      color: theme.textColor.withValues(alpha: 0.9),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // ── Plate number ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              children: [
                Text(
                  'Plate Number',
                  style: TextStyle(
                    color: theme.textColor.withValues(alpha: 0.65),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  plate,
                  style: TextStyle(
                    color: theme.textColor,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section card ────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Color titleColor;
  final List<MapEntry<String, String>> fields;

  const _Section({
    required this.title,
    required this.titleColor,
    required this.fields,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0F0F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: titleColor,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF5F5F5)),
          // Fields
          ...fields.asMap().entries.map((entry) {
            final i = entry.key;
            final e = entry.value;
            final isMoney = _isMoney(e.key, e.value);
            return Column(
              children: [
                _FieldRow(
                  label: e.key,
                  value: isMoney ? _formatMoney(e.value) : e.value,
                  icon: _iconFor(e.key),
                  valueColor: isMoney
                      ? const Color(0xFF15803D)
                      : const Color(0xFF1A1A1A),
                ),
                if (i < fields.length - 1)
                  const Divider(
                      height: 1, color: Color(0xFFF5F5F5),
                      indent: 50),
              ],
            );
          }),
        ],
      ),
    );
  }

  IconData _iconFor(String key) {
    final k = key.toLowerCase();
    if (k.contains('area') || k.contains('location') ||
        k.contains('address') || k.contains('region')) {
      return Icons.location_on_outlined;
    }
    if (k.contains('agency') || k.contains('collector') ||
        k.contains('agent')) {
      return Icons.business_outlined;
    }
    if (k.contains('model') || k.contains('unit') ||
        k.contains('vehicle')) {
      return Icons.directions_car_outlined;
    }
    if (k.contains('color')) return Icons.palette_outlined;
    if (k.contains('balance') || k.contains('amount') ||
        k.contains('loan')) {
      return Icons.account_balance_wallet_outlined;
    }
    if (k.contains('day') || k.contains('due') ||
        k.contains('overdue')) {
      return Icons.calendar_today_outlined;
    }
    if (k.contains('serial') || k.contains('chassis') ||
        k.contains('engine')) {
      return Icons.tag_outlined;
    }
    if (k.contains('status') || k.contains('bucket')) {
      return Icons.info_outline;
    }
    return Icons.chevron_right_rounded;
  }

  bool _isMoney(String key, String value) {
    final keyLower = key.toLowerCase();
    if (!_kMoneyKeywords.any((kw) => keyLower.contains(kw))) return false;
    final stripped = value
        .replaceAll('₱', '')
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .trim();
    return double.tryParse(stripped) != null;
  }

  String _formatMoney(String value) {
    final stripped = value
        .replaceAll('₱', '')
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .trim();
    final number = double.tryParse(stripped);
    if (number == null) return value;
    final isNeg = number < 0;
    final abs = number.abs();
    final intPart = abs.truncate();
    final hasDec = (abs - intPart) > 0.0001;
    final decStr = hasDec
        ? '.${(abs - intPart).toStringAsFixed(2).substring(2)}'
        : '';
    final intStr = intPart.toString();
    final buf = StringBuffer();
    for (int i = 0; i < intStr.length; i++) {
      if (i > 0 && (intStr.length - i) % 3 == 0) buf.write(',');
      buf.write(intStr[i]);
    }
    return '₱ ${isNeg ? "-" : ""}$buf$decStr';
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color valueColor;

  const _FieldRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 13,
                        color: valueColor,
                        fontWeight: FontWeight.w600,
                        height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}