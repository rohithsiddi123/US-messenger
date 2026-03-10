import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class TimeLockedMessageScreen extends StatefulWidget {
  final String chatId;
  final String friendId;
  final String friendName;

  const TimeLockedMessageScreen({
    Key? key,
    required this.chatId,
    required this.friendId,
    required this.friendName,
  }) : super(key: key);

  @override
  State<TimeLockedMessageScreen> createState() =>
      _TimeLockedMessageScreenState();
}

class _TimeLockedMessageScreenState extends State<TimeLockedMessageScreen> {
  final _currentUser = FirebaseAuth.instance.currentUser!;
  final _messageController = TextEditingController();

  String _lockType = 'datetime';
  DateTime _unlockAt = DateTime.now().add(const Duration(hours: 1));
  int _daysAfterSend = 3;
  bool _sending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _unlockAt.isAfter(now) ? _unlockAt : now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_unlockAt),
    );
    if (time == null || !mounted) return;

    final picked = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);

    // Validate: must be in the future
    if (picked.isBefore(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Please pick a future date and time!'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _unlockAt = picked);
  }

  Future<void> _sendTimeLocked() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a message')),
      );
      return;
    }

    // Validate datetime is in the future
    if (_lockType == 'datetime' && !_unlockAt.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Unlock time must be in the future!'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _sending = true);

    try {
      DateTime? unlockAt;
      String lockTypeLabel;

      if (_lockType == 'datetime') {
        unlockAt = _unlockAt;
        lockTypeLabel =
            'Opens at ${DateFormat("MMM d, h:mm a").format(_unlockAt)}';
      } else if (_lockType == 'duration') {
        unlockAt = DateTime.now().add(Duration(days: _daysAfterSend));
        lockTypeLabel =
            'Opens after $_daysAfterSend day${_daysAfterSend > 1 ? "s" : ""}';
      } else {
        unlockAt = null;
        lockTypeLabel = 'Opens when both online';
      }

      final msgData = <String, dynamic>{
        'text': text,
        'senderId': _currentUser.uid,
        'timestamp': FieldValue.serverTimestamp(),
        'saved': false,
        'seen': false,
        'seenAt': null,
        'reactions': {},
        'autoDeleteSeconds': -1,
        'timeLocked': true,
        'lockType': _lockType,
        'unlocked': false,
        'lockLabel': lockTypeLabel,
        'deletedForEveryone': false,
        'deletedFor': {},
      };

      if (unlockAt != null) {
        msgData['unlockAt'] = Timestamp.fromDate(unlockAt);
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add(msgData);

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update({
        'lastMessage': '🔒 Time-locked message',
        'lastMessageTime': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔒 Locked! $lockTypeLabel'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDateInPast = _lockType == 'datetime' &&
        !_unlockAt.isAfter(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('🔒 Time-Locked Message'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Message',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Write something for ${widget.friendName}...',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey[50],
              ),
            ),

            const SizedBox(height: 24),
            const Text('Unlock Condition',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),

            _buildLockTypeCard(
              type: 'datetime',
              icon: '📅',
              title: 'Specific date & time',
              subtitle: 'Opens at an exact moment in the future',
            ),
            _buildLockTypeCard(
              type: 'duration',
              icon: '⏳',
              title: 'After a duration',
              subtitle: 'Opens after X days from now',
            ),
            _buildLockTypeCard(
              type: 'together',
              icon: '💑',
              title: 'When both online',
              subtitle: "Opens only when you're both in the app",
            ),

            const SizedBox(height: 20),

            if (_lockType == 'datetime') ...[
              const Text('Select unlock time:',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _pickDateTime,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDateInPast ? Colors.red[50] : Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: isDateInPast ? Colors.red : Colors.blue),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today,
                          color: isDateInPast ? Colors.red : Colors.blue),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              DateFormat("EEEE, MMM d yyyy • h:mm a")
                                  .format(_unlockAt),
                              style: TextStyle(
                                  color: isDateInPast
                                      ? Colors.red
                                      : Colors.blue,
                                  fontWeight: FontWeight.bold),
                            ),
                            if (isDateInPast)
                              const Text(
                                '⚠️ This time is in the past!',
                                style: TextStyle(
                                    color: Colors.red, fontSize: 12),
                              ),
                            if (!isDateInPast)
                              Text(
                                'Unlocks in ${_timeUntil(_unlockAt)}',
                                style: TextStyle(
                                    color: Colors.blue[400], fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      Icon(Icons.edit,
                          color: isDateInPast ? Colors.red : Colors.blue,
                          size: 18),
                    ],
                  ),
                ),
              ),
            ],

            if (_lockType == 'duration') ...[
              Text(
                'Open after: $_daysAfterSend day${_daysAfterSend > 1 ? "s" : ""}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.blue,
                  thumbColor: Colors.blue,
                  trackHeight: 6,
                ),
                child: Slider(
                  value: _daysAfterSend.toDouble(),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  label: '$_daysAfterSend days',
                  onChanged: (v) =>
                      setState(() => _daysAfterSend = v.toInt()),
                ),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('1 day',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  Text('30 days',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ],

            if (_lockType == 'together') ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.pink[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.pink[200]!),
                ),
                child: Row(
                  children: [
                    const Text('💑', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Message reveals itself only when you and ${widget.friendName} are both using the app at the same time.',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: (_sending || isDateInPast) ? null : _sendTimeLocked,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('🔒', style: TextStyle(fontSize: 18)),
                label: Text(
                  _sending
                      ? 'Sending...'
                      : isDateInPast
                          ? 'Pick a future time first'
                          : 'Lock & Send',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isDateInPast ? Colors.grey : Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeUntil(DateTime dt) {
    final diff = dt.difference(DateTime.now());
    if (diff.inDays > 0) return '${diff.inDays}d ${diff.inHours.remainder(24)}h';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes.remainder(60)}m';
    return '${diff.inMinutes}m';
  }

  Widget _buildLockTypeCard({
    required String type,
    required String icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _lockType == type;
    return GestureDetector(
      onTap: () => setState(() => _lockType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[50] : Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isSelected
                              ? Colors.blue[700]
                              : Colors.black87)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12,
                          color: isSelected
                              ? Colors.blue[400]
                              : Colors.grey)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Colors.blue),
          ],
        ),
      ),
    );
  }
}