import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ChatSettingsScreen extends StatefulWidget {
  final String chatId;
  final String friendName;

  const ChatSettingsScreen({
    Key? key,
    required this.chatId,
    required this.friendName,
  }) : super(key: key);

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  double _timerIndex = 0;
  bool _isLoading = true;

  final List<Map<String, dynamic>> _timerOptions = [
    {'label': 'Off', 'sublabel': 'No auto-delete', 'seconds': -1, 'icon': '🚫'},
    {'label': 'After seen', 'sublabel': 'Delete instantly', 'seconds': 0, 'icon': '👁'},
    {'label': '10 sec', 'sublabel': '10 seconds', 'seconds': 10, 'icon': '⚡'},
    {'label': '1 min', 'sublabel': '1 minute', 'seconds': 60, 'icon': '⏱'},
    {'label': '5 min', 'sublabel': '5 minutes', 'seconds': 300, 'icon': '⏱'},
    {'label': '30 min', 'sublabel': '30 minutes', 'seconds': 1800, 'icon': '🕐'},
    {'label': '1 hr', 'sublabel': '1 hour', 'seconds': 3600, 'icon': '🕐'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();

    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>;
      final savedSeconds = data['autoDeleteSeconds'] ?? -1;
      final index = _timerOptions.indexWhere((o) => o['seconds'] == savedSeconds);
      setState(() {
        _timerIndex = index >= 0 ? index.toDouble() : 0;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    final seconds = _timerOptions[_timerIndex.toInt()]['seconds'];
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .update({'autoDeleteSeconds': seconds});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved ✅'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentOption = _timerOptions[_timerIndex.toInt()];
    final isOff = currentOption['seconds'] == -1;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.friendName} — Settings'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      const Icon(Icons.timer, color: Colors.blue, size: 28),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Disappearing Messages',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Messages delete after being seen',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // Big current value display
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 20),
                      decoration: BoxDecoration(
                        color: isOff ? Colors.grey[100] : Colors.blue[50],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isOff ? Colors.grey[400]! : Colors.blue,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            currentOption['icon'],
                            style: const TextStyle(fontSize: 40),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            currentOption['label'],
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: isOff ? Colors.grey[700] : Colors.blue[700],
                            ),
                          ),
                          Text(
                            currentOption['sublabel'],
                            style: TextStyle(
                              color: isOff ? Colors.grey : Colors.blue[400],
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Slider
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blue,
                      inactiveTrackColor: Colors.grey[300],
                      thumbColor: Colors.blue,
                      overlayColor: Colors.blue.withOpacity(0.2),
                      valueIndicatorColor: Colors.blue,
                      trackHeight: 6,
                    ),
                    child: Slider(
                      value: _timerIndex,
                      min: 0,
                      max: (_timerOptions.length - 1).toDouble(),
                      divisions: _timerOptions.length - 1,
                      label: _timerOptions[_timerIndex.toInt()]['label'],
                      onChanged: (value) =>
                          setState(() => _timerIndex = value),
                    ),
                  ),

                  // Tick labels
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: _timerOptions.map((o) {
                        final isSelected = _timerOptions.indexOf(o) == _timerIndex.toInt();
                        return Text(
                          o['label'],
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected ? Colors.blue : Colors.grey,
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Info box
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber[300]!),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.amber),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Both you and your friend will see the timer. Saved messages (⭐) are not affected.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _saveSettings,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Save Settings',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
