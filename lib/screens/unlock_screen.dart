import 'package:flutter/material.dart';
import 'saved_messages_screen.dart';

class UnlockScreen extends StatefulWidget {
  final String chatId;
  final String userName;

  const UnlockScreen({
    Key? key,
    required this.chatId,
    required this.userName,
  }) : super(key: key);

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  bool _isUnlocked = false;

  void _unlock() {
    setState(() => _isUnlocked = true);

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => SavedMessagesScreen(
              chatId: widget.chatId,
              userName: widget.userName,
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.userName} - Saved Messages'),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: _isUnlocked ? 0.8 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: Icon(
                _isUnlocked ? Icons.lock_open : Icons.lock,
                size: 80,
                color: _isUnlocked ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _isUnlocked
                  ? 'Unlocking...'
                  : 'Unlock to View Saved Messages',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Long press messages in the chat to save them. Your saved messages are protected.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 60),
            if (!_isUnlocked)
              ElevatedButton.icon(
                onPressed: _unlock,
                icon: const Icon(Icons.lock_open),
                label: const Text('Unlock'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 16,
                  ),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }
}