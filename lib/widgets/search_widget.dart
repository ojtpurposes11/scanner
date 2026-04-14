import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/firestore_service.dart';
import '../models/vehicle_model.dart';
import '../widgets/vehicle_result_popup.dart';

// ── Vehicle ID Validation ───────────────────────────────────────
// Plate numbers:        6–7 alphanumeric  e.g. ABC123, ABC1234
// Conduction stickers:  6 alphanumeric    e.g. YA4582, AB1234
// Both formats overlap at 6 chars — treated identically.

bool _isValidVehicleId(String value) {
  final v = value.toUpperCase().trim();
  return RegExp(r'^[A-Z0-9]{6,7}$').hasMatch(v);
}

String _vehicleIdError(String value) {
  final v = value.toUpperCase().trim();
  if (v.isEmpty) return 'Please enter a plate number or conduction sticker.';
  return 'Must be 6–7 characters (e.g. ABC123, ABC1234, or YA4582). Got ${v.length}.';
}

class SearchWidget extends StatefulWidget {
  final VoidCallback onScanCamera;
  // If provided, parent handles showing the result popup.
  final void Function(List<VehicleModel> vehicles, String plate)? onResult;
  // Controls which mode is active when the widget opens.
  final SearchMode initialMode;

  const SearchWidget({
    super.key,
    required this.onScanCamera,
    this.onResult,
    this.initialMode = SearchMode.manual,
  });

  @override
  State<SearchWidget> createState() => _SearchWidgetState();
}

class _SearchWidgetState extends State<SearchWidget> {
  final _searchCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _firestoreService = FirestoreService();
  final _speechToText = SpeechToText();

  bool _searching = false;
  bool _listening = false;
  bool _speechInitialized = false;
  // Inline error shown inside the widget — never behind the bottom sheet
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _initSpeech().then((_) {
      if (widget.initialMode == SearchMode.voice && mounted) {
        Future.delayed(const Duration(milliseconds: 400), _startVoiceSearch);
      }
    });
  }

  Future<void> _initSpeech() async {
    _speechInitialized = await _speechToText.initialize();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focusNode.dispose();
    _speechToText.stop();
    super.dispose();
  }

  Future<void> _search(String input) async {
    final id = input.toUpperCase().trim();

    if (id.isEmpty) {
      setState(() => _inlineError = 'Please enter a plate number or conduction sticker.');
      return;
    }
    if (!_isValidVehicleId(id)) {
      setState(() => _inlineError = _vehicleIdError(id));
      return;
    }

    setState(() { _inlineError = null; _searching = true; });
    _focusNode.unfocus();

    try {
      // ── Ambiguity expansion ──────────────────────────────────────
      // OCR and voice/type input commonly confuse visually similar chars:
      //   B↔8  O↔0  I↔1  S↔5  Z↔2  G↔6  Q↔0
      // We generate all valid-format interpretations and search them all,
      // merging deduplicated results — so "8CD1234" still finds "BCD1234".
      final variants = _expandVariants(id);
      final futures = variants.map((v) => _firestoreService.searchVehicle(v));
      final results = await Future.wait(futures);

      final seen = <String>{};
      final merged = <VehicleModel>[];
      for (final list in results) {
        for (final v in list) {
          final key = v.plateNumber ?? v.toString();
          if (seen.add(key)) merged.add(v);
        }
      }

      if (mounted) {
        if (widget.onResult != null) {
          widget.onResult!(merged, id);
        } else {
          _showResult(merged, id);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _inlineError = 'Search error: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  // ── Generate all valid-format variants of an input ───────────────
  List<String> _expandVariants(String id) {
    const ambig = <String, List<String>>{
      'B': ['B', '8'], 'O': ['O', '0'], 'I': ['I', '1'],
      'S': ['S', '5'], 'Z': ['Z', '2'], 'G': ['G', '6'],
      'Q': ['Q', '0'], 'D': ['D', '0'],
      '8': ['8', 'B'], '0': ['0', 'O'], '1': ['1', 'I'],
      '5': ['5', 'S'], '2': ['2', 'Z'], '6': ['6', 'G'],
    };

    final perPos = id.split('').map((c) => ambig[c] ?? [c]).toList();
    final results = <String>{id};
    _enumerate(perPos, 0, StringBuffer(), results);
    return results.where(_isValidVehicleId).toList();
  }

  void _enumerate(
    List<List<String>> perPos,
    int idx,
    StringBuffer current,
    Set<String> out,
  ) {
    if (idx == perPos.length) {
      out.add(current.toString());
      return;
    }
    for (final ch in perPos[idx]) {
      current.write(ch);
      _enumerate(perPos, idx + 1, current, out);
      final s = current.toString();
      current.clear();
      current.write(s.substring(0, s.length - 1));
    }
  }

  void _showResult(List<VehicleModel> vehicles, String id) {
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
          searchedPlate: id,
          searchMode: widget.initialMode,
          onScanAnother: () => Navigator.pop(context),
          onTypeSearchAnother: () {
            Navigator.pop(context);
            // Clear field so user can type a new search
            setState(() { _searchCtrl.clear(); _inlineError = null; });
          },
          onScanAgain: () => Navigator.pop(context),
          onBackToDashboard: () => Navigator.pop(context),
        ),
      ),
    );
  }

  Future<void> _startVoiceSearch() async {
    if (!_speechInitialized) {
      _speechInitialized = await _speechToText.initialize();
      if (!_speechInitialized) {
        setState(() => _inlineError = 'Microphone not available on this device.');
        return;
      }
    }

    setState(() => _listening = true);
    _showSnack('Listening... Speak the plate or conduction sticker clearly.', isError: false);

    await _speechToText.listen(
      onResult: (result) {
        if (result.finalResult) {
          setState(() => _listening = false);
          final words = result.recognizedWords
              .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
              .toUpperCase();
          if (_isValidVehicleId(words)) {
            _searchCtrl.text = words;
            _search(words);
          } else {
            setState(() => _inlineError =
                'Heard "${result.recognizedWords}" — ${_vehicleIdError(words)} Try again.');
          }
        }
      },
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      localeId: 'en_US',
    );

    Future.delayed(const Duration(seconds: 9), () {
      if (_listening && mounted) {
        _speechToText.stop();
        setState(() => _listening = false);
      }
    });
  }

  void _stopListening() {
    _speechToText.stop();
    setState(() => _listening = false);
  }

  void _showSnack(String message, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[700] : Colors.green[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(12),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Inline error banner — always visible inside the sheet ──
        if (_inlineError != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.red[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red[300]!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    color: Colors.red[700], size: 17),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _inlineError!,
                    style: TextStyle(
                        color: Colors.red[800],
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w500),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _inlineError = null),
                  child: Icon(Icons.close_rounded,
                      size: 16, color: Colors.red[400]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        // Hide text field in voice-only mode
        if (widget.initialMode != SearchMode.voice) ...[
        // Search field + button
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _searchCtrl,
                focusNode: _focusNode,
                maxLength: 7,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.search,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                  _UpperCaseFormatter(),
                ],
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
                decoration: InputDecoration(
                  hintText: 'ABC123  /  ABC1234  /  YA4582',
                  hintStyle: TextStyle(
                    letterSpacing: 1.5,
                    color: Colors.grey[400],
                    fontWeight: FontWeight.w400,
                    fontSize: 13,
                  ),
                  counterText: '',
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                onFieldSubmitted: _search,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 54, height: 54,
              child: ElevatedButton(
                onPressed: _searching ? null : () => _search(_searchCtrl.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF0000),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  disabledBackgroundColor:
                      const Color(0xFFFF0000).withValues(alpha: 0.5),
                ),
                child: _searching
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : const Icon(Icons.search_rounded, size: 24),
              ),
            ),
          ],
        ),

        // Format badges
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
          child: Row(
            children: [
              _FormatBadge(label: 'PLATE', example: 'ABC1234', color: Colors.grey[700]!),
              const SizedBox(width: 8),
              _FormatBadge(label: 'CS', example: 'YA4582', color: Colors.blue[700]!),
            ],
          ),
        ),

        const SizedBox(height: 6),
        ], // end of text field block

        // Bottom action buttons — context-aware per mode
        if (widget.initialMode == SearchMode.voice)
          // Voice mode: mic button — works on both mobile and web browsers
          _QuickActionButton(
            icon: _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
            label: _listening ? 'Listening...' : 'Tap to Listen',
            color: _listening
                ? const Color(0xFFFF0000)
                : const Color(0xFF10B981),
            onTap: _listening ? _stopListening : _startVoiceSearch,
            pulse: _listening,
          )
        else if (widget.initialMode == SearchMode.manual)
          // Manual mode: only the search button — no camera, no voice
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _searching ? null : () => _search(_searchCtrl.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0000),
                foregroundColor: Colors.white,
                elevation: 0,
                disabledBackgroundColor:
                    const Color(0xFFFF0000).withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _searching
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white))
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_rounded,
                            size: 20, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Search',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ],
                    ),
            ),
          )
        else
          // Camera / default mode: both camera and voice buttons
          Row(
            children: [
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.document_scanner_rounded,
                  label: 'Camera Scan',
                  color: const Color(0xFF1A1A1A),
                  onTap: widget.onScanCamera,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickActionButton(
                  icon: _listening
                      ? Icons.mic_rounded
                      : Icons.mic_none_rounded,
                  label: _listening ? 'Listening...' : 'Voice Search',
                  color: _listening
                      ? const Color(0xFFFF0000)
                      : const Color(0xFF555555),
                  onTap: _listening ? _stopListening : _startVoiceSearch,
                  pulse: _listening,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ── Format badge ─────────────────────────────────────────────────

class _FormatBadge extends StatelessWidget {
  final String label;
  final String example;
  final Color color;

  const _FormatBadge({
    required this.label,
    required this.example,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w800, color: color)),
        ),
        const SizedBox(width: 4),
        Text(example,
            style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      ],
    );
  }
}

// ── Quick action button ────────────────────────────────────────────

class _QuickActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool pulse;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.pulse = false,
  });

  @override
  State<_QuickActionButton> createState() => _QuickActionButtonState();
}

class _QuickActionButtonState extends State<_QuickActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        duration: const Duration(milliseconds: 800), vsync: this);
    if (widget.pulse) _pulseCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_QuickActionButton old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !old.pulse) {
      _pulseCtrl.repeat(reverse: true);
    } else if (!widget.pulse && old.pulse) {
      _pulseCtrl.stop();
      _pulseCtrl.reset();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, child) => Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: widget.pulse
                  ? Color.lerp(widget.color,
                      widget.color.withValues(alpha: 0.7), _pulseCtrl.value)
                  : widget.color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: child,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Colors.white, size: 18),
              const SizedBox(width: 7),
              Text(widget.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}