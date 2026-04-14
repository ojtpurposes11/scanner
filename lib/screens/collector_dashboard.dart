import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../models/vehicle_model.dart';
import '../widgets/search_widget.dart';
import '../widgets/vehicle_result_popup.dart';
import 'camera_scanner_export.dart';
import 'entry_screen.dart';
import '../widgets/info_dialog.dart';
import '../widgets/credits_dialog.dart';

class CollectorDashboard extends StatefulWidget {
  const CollectorDashboard({super.key});

  @override
  State<CollectorDashboard> createState() => _CollectorDashboardState();
}

class _CollectorDashboardState extends State<CollectorDashboard> {

  void _logout() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await AuthService().signOut();
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

  void _openVoiceSearch() => _showSearchSheet(mode: SearchMode.voice);
  void _openManualSearch() => _showSearchSheet(mode: SearchMode.manual);

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
            child: Column(
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

                        // Camera — opens camera scanner directly
                        _DashCard(
                          icon: Icons.camera_alt_outlined,
                          label: 'Camera Scan',
                          subtitle: 'Scan a plate using your camera',
                          filled: true,
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(
                                  builder: (_) => const CameraScannerScreen())),
                        ),
                        const SizedBox(height: 12),

                        // Voice — opens voice-only search sheet
                        _DashCard(
                          icon: Icons.mic_none_rounded,
                          label: 'Voice Search',
                          subtitle: 'Search by speaking the plate number',
                          filled: false,
                          onTap: _openVoiceSearch,
                        ),
                        const SizedBox(height: 12),

                        // Manual — opens text-only search sheet
                        _DashCard(
                          icon: Icons.search_rounded,
                          label: 'Type Search',
                          subtitle: 'Manually type the plate number',
                          filled: true,
                          onTap: _openManualSearch,
                        ),
                        // No Admin Tools / Upload Database for Field Collectors
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
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
          colors: [Color(0xFF1A1A1A), Color(0xFF3A3A3A)],
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
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.directions_car_filled_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 10),
              const Text('Collector Dashboard',
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
                  Text(greeting + ', Collector!',
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
}

// ── Section label ────────────────────────────────────────────────

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

// ── Full-width dashboard card ────────────────────────────────────

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
    final bool active = _pressed || _hovered;

    final Color bgColor = widget.filled
        ? active ? const Color(0xFFCC0000) : const Color(0xFFFF0000)
        : active ? const Color(0xFFFFF0F0) : Colors.white;

    final Color iconCircleBg = widget.filled
        ? Colors.white.withValues(alpha: active ? 0.35 : 0.22)
        : active ? Colors.red[100]! : Colors.red[50]!;

    final Color iconColor = widget.filled ? Colors.white : const Color(0xFFFF0000);
    final Color titleColor = widget.filled ? Colors.white : const Color(0xFFFF0000);
    final Color subtitleColor = widget.filled
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.grey[500]!;

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