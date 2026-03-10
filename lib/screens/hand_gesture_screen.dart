import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'saved_messages_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

class HandGestureScreen extends StatefulWidget {
  final String chatId;
  final String friendName;

  const HandGestureScreen({
    Key? key,
    required this.chatId,
    required this.friendName,
  }) : super(key: key);

  @override
  State<HandGestureScreen> createState() => _HandGestureScreenState();
}

class _HandGestureScreenState extends State<HandGestureScreen> {
  static const _methodChannel = MethodChannel('com.example.us/gesture');
  static const _eventChannel = EventChannel('com.example.us/gesture_events');

  String _currentGesture = 'None';
  double _confidence = 0.0;
  List<List<Map<String, double>>> _landmarks = [];
  bool _isStarted = false;
  bool _navigating = false;
  String _statusText = 'Show gesture to open saved messages';
  int _gestureFrameCount = 0;
  static const int _requiredFrames = 20;
  StreamSubscription? _gestureSub;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      await _methodChannel.invokeMethod('startCamera');
      if (mounted) {
        setState(() => _isStarted = true);
        _listenToGestures();
      }
    } catch (e) {
      if (mounted) setState(() => _statusText = 'Camera error: $e');
    }
  }

  void _listenToGestures() {
    try {
      _gestureSub = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (!mounted || _navigating) return;

          final gesture = data['gesture'] as String? ?? 'None';
          final confidence = (data['confidence'] as num?)?.toDouble() ?? 0.0;
          final rawLandmarks = data['landmarks'] as List? ?? [];

          final landmarks = rawLandmarks.map((hand) {
            return (hand as List).map((lm) {
              final m = lm as Map;
              return <String, double>{
                'x': (m['x'] as num).toDouble(),
                'y': (m['y'] as num).toDouble(),
                'z': (m['z'] as num).toDouble(),
              };
            }).toList();
          }).toList();

          if (!mounted) return;
          setState(() {
            _currentGesture = gesture;
            _confidence = confidence;
            _landmarks = landmarks;
          });

          if (gesture == 'Victory' && confidence > 0.7) {
            _gestureFrameCount++;
            final progress =
                (_gestureFrameCount / _requiredFrames * 100).toInt();
            if (mounted)
              setState(() => _statusText = 'Hold it... $progress%');

            if (_gestureFrameCount >= _requiredFrames && !_navigating) {
              _navigating = true;
              _stopCameraAndNavigate();
            }
          } else {
            _gestureFrameCount = 0;
            if (mounted)
              setState(() =>
                  _statusText = 'Show gesture to open saved messages');
          }
        },
        onError: (error) {
          debugPrint('Gesture stream error: $error');
          if (mounted)
            setState(() => _statusText = 'Gesture error — try again');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('Failed to listen gestures: $e');
    }
  }

  Future<void> _stopCameraAndNavigate() async {
    _gestureSub?.cancel();
    try {
      await _methodChannel.invokeMethod('stopCamera');
    } catch (_) {}
    if (mounted) {
      final currentUser = FirebaseAuth.instance.currentUser;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => SavedMessagesScreen(
            chatId: widget.chatId,
            friendName: widget.friendName,
            currentUserId: currentUser?.uid ?? '',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    if (!_navigating) {
      _methodChannel.invokeMethod('stopCamera').catchError((_) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVictory = _currentGesture == 'Victory';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Secret Gesture',
            style: TextStyle(color: Colors.white)),
        centerTitle: true,
      ),
      body: !_isStarted
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text('Starting camera...',
                      style: TextStyle(color: Colors.white)),
                ],
              ),
            )
          : Stack(
              children: [
                Positioned.fill(child: Container(color: Colors.black)),

                if (_landmarks.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: HandSkeletonPainter(
                        landmarks: _landmarks,
                        gesture: _currentGesture,
                      ),
                    ),
                  ),

                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Show gesture sign to camera',
                        style:
                            TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ),
                ),

                if (_currentGesture != 'None')
                  Positioned(
                    top: 70,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isVictory
                              ? Colors.green.withOpacity(0.8)
                              : Colors.red.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$_currentGesture (${(_confidence * 100).toStringAsFixed(0)}%)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),

                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.9),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Column(
                      children: [
                        if (_gestureFrameCount > 0)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value:
                                    _gestureFrameCount / _requiredFrames,
                                backgroundColor: Colors.white24,
                                color: Colors.greenAccent,
                                minHeight: 8,
                              ),
                            ),
                          ),
                        Text(
                          _statusText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Point front camera at your hand',
                          style: TextStyle(
                              color: Colors.white60, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class HandSkeletonPainter extends CustomPainter {
  final List<List<Map<String, double>>> landmarks;
  final String gesture;

  HandSkeletonPainter({required this.landmarks, required this.gesture});

  @override
  void paint(Canvas canvas, Size size) {
    final isVictory = gesture == 'Victory';

    final dotPaint = Paint()
      ..color = isVictory ? Colors.greenAccent : Colors.white
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..color =
          (isVictory ? Colors.greenAccent : Colors.white).withOpacity(0.7)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    const connections = [
      [0, 1], [1, 2], [2, 3], [3, 4],
      [0, 5], [5, 6], [6, 7], [7, 8],
      [0, 9], [9, 10], [10, 11], [11, 12],
      [0, 13], [13, 14], [14, 15], [15, 16],
      [0, 17], [17, 18], [18, 19], [19, 20],
      [5, 9], [9, 13], [13, 17],
    ];

    for (final hand in landmarks) {
      if (hand.length < 21) continue;
      for (final conn in connections) {
        final a = hand[conn[0]];
        final b = hand[conn[1]];
        canvas.drawLine(
          Offset(a['x']! * size.width, a['y']! * size.height),
          Offset(b['x']! * size.width, b['y']! * size.height),
          linePaint,
        );
      }
      for (int i = 0; i < hand.length; i++) {
        final lm = hand[i];
        final radius = [4, 8, 12, 16, 20].contains(i) ? 7.0 : 5.0;
        canvas.drawCircle(
          Offset(lm['x']! * size.width, lm['y']! * size.height),
          radius,
          dotPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(HandSkeletonPainter oldDelegate) => true;
}