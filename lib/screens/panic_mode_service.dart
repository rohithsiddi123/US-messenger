import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PanicModeService {
  static bool _isPanicActive = false;
  static bool get isPanicActive => _isPanicActive;

  /// Called when 3 shakes detected.
  /// Wipes all chat messages, logs out, triggers fake UI.
  static Future<void> activatePanic(BuildContext context) async {
    if (_isPanicActive) return;
    _isPanicActive = true;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // 1. Wipe all chats the user is in
      final chats = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      for (final chatDoc in chats.docs) {
        // Delete all messages in each chat
        final messages = await chatDoc.reference
            .collection('messages')
            .get();
        for (final msg in messages.docs) {
          await msg.reference.delete();
        }
        // Update last message
        await chatDoc.reference.update({
          'lastMessage': '',
          'lastMessageTime': FieldValue.serverTimestamp(),
        });
      }

      // 2. Sign out
      await FirebaseAuth.instance.signOut();

      // 3. Show fake UI — navigate to decoy screen
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const FakeAppScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      debugPrint('Panic mode error: $e');
    }
  }

  static void reset() => _isPanicActive = false;
}

/// Fake app UI — looks like a boring notes/calculator app
class FakeAppScreen extends StatefulWidget {
  const FakeAppScreen({Key? key}) : super(key: key);

  @override
  State<FakeAppScreen> createState() => _FakeAppScreenState();
}

class _FakeAppScreenState extends State<FakeAppScreen> {
  String _display = '0';
  String _expression = '';

  void _press(String val) {
    setState(() {
      if (val == 'C') {
        _display = '0';
        _expression = '';
      } else if (val == '=') {
        try {
          // Simple eval
          final result = _evalExpression(_expression);
          _display = result;
          _expression = result;
        } catch (_) {
          _display = 'Error';
          _expression = '';
        }
      } else {
        if (_display == '0' && !['.','+','-','×','÷'].contains(val)) {
          _display = val;
          _expression = val;
        } else {
          _display += val;
          _expression += val;
        }
      }
    });
  }

  String _evalExpression(String expr) {
    expr = expr.replaceAll('×', '*').replaceAll('÷', '/');
    // Basic two-operand evaluation
    for (final op in ['+', '-', '*', '/']) {
      final parts = expr.split(op);
      if (parts.length == 2) {
        final a = double.tryParse(parts[0]);
        final b = double.tryParse(parts[1]);
        if (a != null && b != null) {
          double result;
          if (op == '+') result = a + b;
          else if (op == '-') result = a - b;
          else if (op == '*') result = a * b;
          else result = b != 0 ? a / b : double.nan;
          return result % 1 == 0
              ? result.toInt().toString()
              : result.toStringAsFixed(2);
        }
      }
    }
    return expr;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: null,
      body: SafeArea(
        child: Column(
          children: [
            // Display
            Expanded(
              flex: 2,
              child: Container(
                alignment: Alignment.bottomRight,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _expression.isEmpty ? '' : _expression,
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 24),
                    ),
                    Text(
                      _display,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 64,
                          fontWeight: FontWeight.w200),
                    ),
                  ],
                ),
              ),
            ),

            // Buttons
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _buildRow(['C', '+/-', '%', '÷'],
                        [Colors.grey[600]!, Colors.grey[600]!, Colors.grey[600]!, Colors.orange]),
                    _buildRow(['7', '8', '9', '×'],
                        [Colors.grey[800]!, Colors.grey[800]!, Colors.grey[800]!, Colors.orange]),
                    _buildRow(['4', '5', '6', '-'],
                        [Colors.grey[800]!, Colors.grey[800]!, Colors.grey[800]!, Colors.orange]),
                    _buildRow(['1', '2', '3', '+'],
                        [Colors.grey[800]!, Colors.grey[800]!, Colors.grey[800]!, Colors.orange]),
                    _buildRow(['0', '.', '⌫', '='],
                        [Colors.grey[800]!, Colors.grey[800]!, Colors.grey[800]!, Colors.orange]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(List<String> labels, List<Color> colors) {
    return Expanded(
      child: Row(
        children: List.generate(labels.length, (i) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: GestureDetector(
                onTap: () => _press(labels[i]),
                child: Container(
                  decoration: BoxDecoration(
                    color: colors[i],
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
