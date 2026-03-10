import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math';
import 'panic_mode_service.dart';

class PanicDetector extends StatefulWidget {
  final Widget child;

  const PanicDetector({Key? key, required this.child}) : super(key: key);

  @override
  State<PanicDetector> createState() => _PanicDetectorState();
}

class _PanicDetectorState extends State<PanicDetector> {
  StreamSubscription? _accelSub;
  int _shakeCount = 0;
  DateTime? _lastShakeTime;
  static const double _shakeThreshold = 15.0;
  static const int _requiredShakes = 3;
  static const int _shakeWindowMs = 2000; // 3 shakes within 2 seconds

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  void _startListening() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      final acceleration = sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);

      // Detect shake — subtract gravity (9.8)
      if (acceleration - 9.8 > _shakeThreshold) {
        final now = DateTime.now();

        // Reset if outside window
        if (_lastShakeTime != null &&
            now.difference(_lastShakeTime!).inMilliseconds > _shakeWindowMs) {
          _shakeCount = 0;
        }

        _shakeCount++;
        _lastShakeTime = now;

        if (_shakeCount >= _requiredShakes) {
          _shakeCount = 0;
          _triggerPanic();
        }
      }
    });
  }

  void _triggerPanic() {
    if (!mounted) return;
    PanicModeService.activatePanic(context);
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
