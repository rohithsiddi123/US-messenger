import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({Key? key}) : super(key: key);

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  static const int _size = 4;

  List<List<int>> _board = [];
  int _score = 0;
  int _best = 0;
  bool _gameOver = false;
  bool _won = false;
  bool _keepPlaying = false;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  // ── Two-finger long press to dismiss ─────────────────────────────────────
  int _pointerCount = 0;
  Timer? _dismissTimer;
  bool _showDismissHint = false;
  static const _dismissDuration = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 8).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );
    _newGame();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _dismissTimer?.cancel();
    super.dispose();
  }

  // ── Two-finger dismiss handlers ───────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _pointerCount++;
    if (_pointerCount == 2) {
      _dismissTimer?.cancel();
      setState(() => _showDismissHint = true);
      _dismissTimer = Timer(_dismissDuration, () {
        if (mounted) {
          HapticFeedback.mediumImpact();
          Navigator.pop(context);
        }
      });
    } else if (_pointerCount > 2) {
      _dismissTimer?.cancel();
      if (mounted) setState(() => _showDismissHint = false);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerCount = (_pointerCount - 1).clamp(0, 10);
    if (_pointerCount < 2) {
      _dismissTimer?.cancel();
      if (mounted) setState(() => _showDismissHint = false);
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointerCount = (_pointerCount - 1).clamp(0, 10);
    _dismissTimer?.cancel();
    if (mounted) setState(() => _showDismissHint = false);
  }

  // ── Game logic ────────────────────────────────────────────────────────────

  void _newGame() {
    _board = List.generate(_size, (_) => List.filled(_size, 0));
    _score = 0;
    _gameOver = false;
    _won = false;
    _keepPlaying = false;
    _addRandom();
    _addRandom();
    setState(() {});
  }

  void _addRandom() {
    final empty = <List<int>>[];
    for (int r = 0; r < _size; r++) {
      for (int c = 0; c < _size; c++) {
        if (_board[r][c] == 0) empty.add([r, c]);
      }
    }
    if (empty.isEmpty) return;
    final pick = empty[Random().nextInt(empty.length)];
    _board[pick[0]][pick[1]] = Random().nextInt(10) < 9 ? 2 : 4;
  }

  bool _canMove() {
    for (int r = 0; r < _size; r++) {
      for (int c = 0; c < _size; c++) {
        if (_board[r][c] == 0) return true;
        if (c < _size - 1 && _board[r][c] == _board[r][c + 1]) return true;
        if (r < _size - 1 && _board[r][c] == _board[r + 1][c]) return true;
      }
    }
    return false;
  }

  // Returns [newRow, points]
  List _mergeRow(List<int> row) {
    // Slide non-zeros left
    List<int> vals = row.where((v) => v != 0).toList();
    int pts = 0;
    for (int i = 0; i < vals.length - 1; i++) {
      if (vals[i] == vals[i + 1]) {
        vals[i] *= 2;
        pts += vals[i];
        vals[i + 1] = 0;
      }
    }
    vals = vals.where((v) => v != 0).toList();
    while (vals.length < _size) vals.add(0);
    return [vals, pts];
  }

  bool _move(String dir) {
    List<List<int>> before =
        _board.map((r) => List<int>.from(r)).toList();
    int gained = 0;

    if (dir == 'left') {
      for (int r = 0; r < _size; r++) {
        final res = _mergeRow(_board[r]);
        _board[r] = res[0];
        gained += res[1] as int;
      }
    } else if (dir == 'right') {
      for (int r = 0; r < _size; r++) {
        final res = _mergeRow(_board[r].reversed.toList());
        _board[r] = (res[0] as List<int>).reversed.toList();
        gained += res[1] as int;
      }
    } else if (dir == 'up') {
      for (int c = 0; c < _size; c++) {
        final col = List<int>.generate(_size, (r) => _board[r][c]);
        final res = _mergeRow(col);
        final merged = res[0] as List<int>;
        for (int r = 0; r < _size; r++) _board[r][c] = merged[r];
        gained += res[1] as int;
      }
    } else if (dir == 'down') {
      for (int c = 0; c < _size; c++) {
        final col =
            List<int>.generate(_size, (r) => _board[r][c]).reversed.toList();
        final res = _mergeRow(col);
        final merged = (res[0] as List<int>).reversed.toList();
        for (int r = 0; r < _size; r++) _board[r][c] = merged[r];
        gained += res[1] as int;
      }
    }

    // Check if board changed
    bool changed = false;
    for (int r = 0; r < _size; r++) {
      for (int c = 0; c < _size; c++) {
        if (_board[r][c] != before[r][c]) {
          changed = true;
          break;
        }
      }
    }

    if (!changed) return false;

    _score += gained;
    if (_score > _best) _best = _score;

    _addRandom();

    // Check win
    if (!_won || _keepPlaying) {
      for (var row in _board) {
        if (row.contains(2048)) {
          if (!_keepPlaying) _won = true;
        }
      }
    }

    // Check game over
    if (!_canMove()) {
      _gameOver = true;
      _shakeController.forward(from: 0);
      HapticFeedback.heavyImpact();
    } else if (gained > 0) {
      HapticFeedback.lightImpact();
    }

    return true;
  }

  // ── Swipe detection ───────────────────────────────────────────────────────

  Offset? _dragStart;

  void _onPanStart(DragStartDetails d) => _dragStart = d.globalPosition;

  void _onPanEnd(DragEndDetails d) {
    if (_dragStart == null || _gameOver) return;
    if (_won && !_keepPlaying) return;

    final dx = d.velocity.pixelsPerSecond.dx;
    final dy = d.velocity.pixelsPerSecond.dy;
    String? dir;

    if (dx.abs() > dy.abs()) {
      if (dx.abs() > 200) dir = dx > 0 ? 'right' : 'left';
    } else {
      if (dy.abs() > 200) dir = dy > 0 ? 'down' : 'up';
    }

    if (dir != null) setState(() => _move(dir!));
  }

  // ── Tile colors ───────────────────────────────────────────────────────────

  Color _tileColor(int val) {
    switch (val) {
      case 0:    return const Color(0xFFCDC1B4);
      case 2:    return const Color(0xFFEEE4DA);
      case 4:    return const Color(0xFFEDE0C8);
      case 8:    return const Color(0xFFF2B179);
      case 16:   return const Color(0xFFF59563);
      case 32:   return const Color(0xFFF67C5F);
      case 64:   return const Color(0xFFF65E3B);
      case 128:  return const Color(0xFFEDCF72);
      case 256:  return const Color(0xFFEDCC61);
      case 512:  return const Color(0xFFEDC850);
      case 1024: return const Color(0xFFEDC53F);
      case 2048: return const Color(0xFFEDC22E);
      default:   return const Color(0xFF3C3A32);
    }
  }

  Color _textColor(int val) =>
      val <= 4 ? const Color(0xFF776E65) : Colors.white;

  double _fontSize(int val) {
    if (val < 100)   return 32;
    if (val < 1000)  return 26;
    if (val < 10000) return 20;
    return 16;
  }

  // ── Widgets ───────────────────────────────────────────────────────────────

  Widget _buildTile(int val) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _tileColor(val),
        borderRadius: BorderRadius.circular(8),
        boxShadow: val > 0
            ? [BoxShadow(color: Colors.black26, blurRadius: 4, offset: const Offset(0, 2))]
            : [],
      ),
      child: Center(
        child: val > 0
            ? Text(
                '$val',
                style: TextStyle(
                  fontSize: _fontSize(val),
                  fontWeight: FontWeight.bold,
                  color: _textColor(val),
                  fontFamily: 'Arial',
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildBoard() {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: _gameOver
              ? Offset(
                  sin(_shakeController.value * pi * 6) *
                      _shakeAnimation.value,
                  0)
              : Offset.zero,
          child: child,
        );
      },
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanEnd: _onPanEnd,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFBBADA0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _size,
              ),
              itemCount: _size * _size,
              itemBuilder: (_, i) {
                final r = i ~/ _size;
                final c = i % _size;
                return _buildTile(_board[r][c]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _scoreBox(String label, int value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFBBADA0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFFEEE4DA),
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text('$value',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
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
          Scaffold(
            backgroundColor: const Color(0xFFFAF8EF),
            appBar: AppBar(
              backgroundColor: const Color(0xFFFAF8EF),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF776E65)),
                onPressed: () => Navigator.pop(context),
              ),
              title: const Text(
                '2048',
                style: TextStyle(
                  color: Color(0xFF776E65),
                  fontWeight: FontWeight.bold,
                  fontSize: 32,
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh, color: Color(0xFF776E65)),
                  onPressed: () => setState(_newGame),
                  tooltip: 'New Game',
                ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    // Score row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Join tiles to get 2048!',
                          style: TextStyle(
                              color: Color(0xFF776E65), fontSize: 13),
                        ),
                        Row(
                          children: [
                            _scoreBox('SCORE', _score),
                            const SizedBox(width: 8),
                            _scoreBox('BEST', _best),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Board
                    _buildBoard(),

                    const SizedBox(height: 16),

                    // How to play
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE0C8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '🎯  Swipe to move tiles. Tiles with the same number merge. Reach 2048 to win!\n\n👆  Two-finger hold anywhere to go back.',
                        style: TextStyle(
                            color: Color(0xFF776E65), fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),

                    // Win / Game Over overlays
                    if (_gameOver || (_won && !_keepPlaying)) ...[
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _won
                              ? const Color(0xFFEDC22E)
                              : const Color(0xFF776E65),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              _won ? '🎉 You won!' : '😢 Game over!',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Score: $_score',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 16),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                ElevatedButton(
                                  onPressed: () => setState(_newGame),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor:
                                        const Color(0xFF776E65),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(8)),
                                  ),
                                  child: const Text('New Game',
                                      style: TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                                if (_won) ...[
                                  const SizedBox(width: 12),
                                  ElevatedButton(
                                    onPressed: () => setState(
                                        () => _keepPlaying = true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          const Color(0xFFF65E3B),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(
                                                  8)),
                                    ),
                                    child: const Text(
                                        'Keep Playing',
                                        style: TextStyle(
                                            fontWeight:
                                                FontWeight.bold)),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // ── Two-finger dismiss hint overlay ───────────────────────────
          if (_showDismissHint)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showDismissHint ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    color: Colors.black45,
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
                            Text('👆👆',
                                style: TextStyle(fontSize: 36)),
                            SizedBox(height: 10),
                            Text(
                              'Hold to go back…',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF776E65),
                              ),
                            ),
                          ],
                        ),
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
