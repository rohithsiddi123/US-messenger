import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'game_screen.dart';

/// Wrap any screen body with this widget.
/// Two-finger hold for 600ms → 2048 slides up as a full modal.
/// Inside the game, two-finger hold for 600ms → slides back down.
class TwoFingerLongPressWrapper extends StatefulWidget {
  final Widget child;

  const TwoFingerLongPressWrapper({Key? key, required this.child})
      : super(key: key);

  @override
  State<TwoFingerLongPressWrapper> createState() =>
      _TwoFingerLongPressWrapperState();
}

class _TwoFingerLongPressWrapperState
    extends State<TwoFingerLongPressWrapper> {
  int _pointerCount = 0;
  Timer? _holdTimer;
  bool _triggered = false;
  bool _showHint = false;

  static const _holdDuration = Duration(milliseconds: 600);

  void _onPointerDown(PointerDownEvent e) {
    _pointerCount++;
    if (_pointerCount == 2 && !_triggered) {
      if (mounted) setState(() => _showHint = true);
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, _openGame);
    } else if (_pointerCount > 2) {
      _cancelTimer();
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerCount = (_pointerCount - 1).clamp(0, 10);
    if (_pointerCount < 2) _cancelTimer();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointerCount = (_pointerCount - 1).clamp(0, 10);
    _cancelTimer();
  }

  void _cancelTimer() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (mounted) setState(() => _showHint = false);
  }

  void _openGame() {
    if (!mounted) return;
    _triggered = true;
    _pointerCount = 0;
    if (mounted) setState(() => _showHint = false);
    HapticFeedback.mediumImpact();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.93,
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          child: GameScreen(),
        ),
      ),
    ).whenComplete(() {
      _triggered = false;
      _pointerCount = 0;
      if (mounted) setState(() => _showHint = false);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          widget.child,

          // ── Hold hint overlay ─────────────────────────────────────────
          if (_showHint)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black38,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 16,
                              offset: Offset(0, 4))
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text('🎮', style: TextStyle(fontSize: 40)),
                          SizedBox(height: 10),
                          Text(
                            'Hold to open game…',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
