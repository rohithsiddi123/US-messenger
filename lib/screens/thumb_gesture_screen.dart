import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'chat_screen.dart';

class ThumbGestureScreen extends StatefulWidget {
  final String chatId;
  final String friendId;
  final String friendName;

  const ThumbGestureScreen({
    Key? key,
    required this.chatId,
    required this.friendId,
    required this.friendName,
  }) : super(key: key);

  @override
  State<ThumbGestureScreen> createState() => _ThumbGestureScreenState();
}

class _ThumbGestureScreenState extends State<ThumbGestureScreen> {
  static const _methodChannel = MethodChannel('com.example.us/gesture');
  static const _eventChannel = EventChannel('com.example.us/gesture_events');

  String _currentGesture = 'None';
  double _confidence = 0.0;
  List<List<Map<String, double>>> _landmarks = [];
  bool _isStarted = false;
  bool _navigating = false;
  String _statusText = 'Show gestureto open chat';
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

          if (gesture == 'Thumb_Up' && confidence > 0.7) {
            _gestureFrameCount++;
            final progress =
                (_gestureFrameCount / _requiredFrames * 100).toInt();
            if (mounted) setState(() => _statusText = 'Hold it... $progress%');

            if (_gestureFrameCount >= _requiredFrames && !_navigating) {
              _navigating = true;
              _stopCameraAndOpenChat();
            }
          } else {
            _gestureFrameCount = 0;
            if (mounted) setState(() => _statusText = 'Show gestureto open chat');
          }
        },
        onError: (error) {
          debugPrint('Gesture stream error: $error');
          if (mounted) setState(() => _statusText = 'Gesture error — try again');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('Failed to listen gestures: $e');
    }
  }

  Future<void> _stopCameraAndOpenChat() async {
    _gestureSub?.cancel();
    try {
      await _methodChannel.invokeMethod('stopCamera');
    } catch (_) {}
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: widget.chatId,
            friendId: widget.friendId,
            friendName: widget.friendName,
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
    final isThumbUp = _currentGesture == 'Thumb_Up';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.friendName,
            style: const TextStyle(color: Colors.white)),
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
                        isTarget: isThumbUp,
                      ),
                    ),
                  ),

                Positioned(
                  top: 16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Column(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              isThumbUp ? Colors.green : Colors.blue,
                          radius: 28,
                          child: Text(
                            widget.friendName[0].toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            ' Show gesture to open chat',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_currentGesture != 'None')
                  Positioned(
                    top: 130,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isThumbUp
                              ? Colors.green.withOpacity(0.85)
                              : Colors.red.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${isThumbUp ? '👍' : '🤔'} $_currentGesture (${(_confidence * 100).toStringAsFixed(0)}%)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
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
                          Colors.black.withOpacity(0.95),
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
                          style: TextStyle(
                            color: isThumbUp
                                ? Colors.greenAccent
                                : Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Point front camera at your hand',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 13),
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
  final bool isTarget;

  HandSkeletonPainter({required this.landmarks, required this.isTarget});

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()
      ..color = isTarget ? Colors.greenAccent : Colors.white
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..color =
          (isTarget ? Colors.greenAccent : Colors.white).withOpacity(0.7)
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