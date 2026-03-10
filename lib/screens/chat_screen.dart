import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'saved_messages_screen.dart';
import 'hand_gesture_screen.dart';
import 'chat_settings_screen.dart';
import 'time_locked_message_screen.dart';
import 'package:us/services/e2ee_service.dart';
import 'two_finger_long_press_wrapper.dart';
import 'sad_face_screen.dart';
import 'panic_detector.dart';
import 'dart:async';
import 'dart:math';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String friendId;
  final String friendName;

  const ChatScreen({
    Key? key,
    required this.chatId,
    required this.friendId,
    required this.friendName,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _currentUser = FirebaseAuth.instance.currentUser!;
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _e2ee = E2EEService();

  int _tapCount = 0;
  DateTime? _lastTapTime;
  int _autoDeleteSeconds = -1;
  bool _disappearingMode = false;

  Map<String, dynamic>? _replyToMessage;
  String? _replyToId;

  String? _editingMessageId;
  bool _isEditing = false;

  bool _friendOnline = false;
  DateTime? _friendLastSeen;
  bool _friendTyping = false;

  // E2EE
  bool _e2eeReady = false;
  final Map<String, String> _decryptedCache = {};

  Timer? _typingTimer;
  bool _isTyping = false;

  static const _morseChannel = MethodChannel('com.example.us/morse');
  final List<String> _emojis = ['👍', '❤️', '😂', '😮', '😢', '😡'];

  StreamSubscription? _screenshotSub;
  static const _screenshotEventChannel =
      EventChannel('com.example.us/screenshot_events');

  Timer? _presenceTimer;
  Timer? _unlockTimer;
  StreamSubscription? _messageListener;
  StreamSubscription? _friendStatusSub;
  String? _lastKnownMessageId;

  int _pendingNotificationCount = 0;
  Timer? _notificationBatchTimer;
  DateTime? _lastSeenCheck; // throttle _markMessagesAsSeen


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initE2EE();
    _loadChatSettings();
    _listenForScreenshots();
    _updatePresence(true);
    _checkTogetherMessages();
    _unlockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _unlockDueMessages();
    });
    _unlockDueMessages();
    _listenForIncomingMessages();
    _listenFriendStatus();
    _checkDisappearingMessages();
  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _screenshotSub?.cancel();
    _presenceTimer?.cancel();
    _unlockTimer?.cancel();
    _messageListener?.cancel();
    _friendStatusSub?.cancel();
    _typingTimer?.cancel();
    _notificationBatchTimer?.cancel();
    _setTyping(false);
    _updatePresence(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updatePresence(true);
      _checkTogetherMessages();
    } else {
      _updatePresence(false);
      _setTyping(false);
    }
  }

  // ── E2EE ──────────────────────────────────────────────────────────────────

  Future<void> _initE2EE() async {
    // initKeys is fast if keys already exist in secure storage (just a read).
    // First-time key generation (RSA-2048) is slow ~2s — but that only
    // happens once ever on this device. We run it async so UI stays responsive.
    _e2ee.initKeys().then((_) {
      if (mounted) {
        // Clear any failed decrypt entries so messages re-decrypt with fresh keys
        _decryptedCache.removeWhere((_, v) => v.startsWith('['));
        setState(() => _e2eeReady = true);
      }
    }).catchError((e) {
      debugPrint('E2EE init error: $e');
    });
  }

  Future<String> _decryptText(String messageId, String rawText) async {
    if (_decryptedCache.containsKey(messageId)) {
      return _decryptedCache[messageId]!;
    }
    if (!_e2ee.isEncrypted(rawText)) {
      _decryptedCache[messageId] = rawText;
      return rawText;
    }
    final decrypted = await _e2ee.decryptMessage(rawText);
    // Only cache successful decryptions — never cache error strings
    if (!decrypted.startsWith('[')) {
      _decryptedCache[messageId] = decrypted;
    }
    return decrypted;
  }

  // ── Friend status ─────────────────────────────────────────────────────────

  void _listenFriendStatus() {
    _friendStatusSub = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.friendId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data() as Map<String, dynamic>;
      final newOnline  = data['online'] == true;
      final newSeen    = (data['lastSeen'] as Timestamp?)?.toDate();
      final newTyping  = data['typingIn'] == widget.chatId;
      // Only rebuild if something actually changed
      if (newOnline != _friendOnline ||
          newSeen   != _friendLastSeen ||
          newTyping != _friendTyping) {
        setState(() {
          _friendOnline   = newOnline;
          _friendLastSeen = newSeen;
          _friendTyping   = newTyping;
        });
      }
    });
  }

  String _friendStatusText() {
    if (_friendTyping) return 'typing...';
    if (_friendOnline) return 'Online';
    if (_friendLastSeen == null) return '';
    final diff = DateTime.now().difference(_friendLastSeen!);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Last seen yesterday';
    return 'Last seen ${diff.inDays} days ago';
  }

  // ── Typing indicator ──────────────────────────────────────────────────────

  void _onTextChanged(String value) {
    // Only write to Firestore when typing state CHANGES — not every keystroke
    if (value.isNotEmpty && !_isTyping) {
      _isTyping = true;
      _setTyping(true);
    }
    _typingTimer?.cancel();
    if (value.isEmpty) {
      if (_isTyping) {
        _isTyping = false;
        _setTyping(false);
      }
      return;
    }
    _typingTimer = Timer(const Duration(seconds: 3), () {
      _isTyping = false;
      _setTyping(false);
    });
  }

  // Never await this — it must never block the UI thread
  void _setTyping(bool typing) {
    FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser.uid)
        .update({'typingIn': typing ? widget.chatId : null})
        .catchError((_) {});
  }

  // ── Disappearing messages ─────────────────────────────────────────────────

  Future<void> _checkDisappearingMessages() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        if (mounted) {
          setState(() => _disappearingMode = data['disappearing24h'] == true);
        }
        if (_disappearingMode) _deleteExpiredMessages();
      }
    } catch (_) {}
  }

  Future<void> _deleteExpiredMessages() async {
    try {
      final cutoff = Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 24)));
      final old = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .where('timestamp', isLessThan: cutoff)
          .get();
      for (final doc in old.docs) {
        await doc.reference.delete();
      }
    } catch (_) {}
  }

  Future<void> _toggleDisappearing() async {
    final newVal = !_disappearingMode;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update({'disappearing24h': newVal});
      setState(() => _disappearingMode = newVal);
      if (newVal) _deleteExpiredMessages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newVal
              ? '⏱️ Disappearing messages ON — 24h'
              : 'Disappearing messages OFF'),
          backgroundColor: newVal ? Colors.orange : Colors.grey,
        ));
      }
    } catch (_) {}
  }

  // ── Presence ──────────────────────────────────────────────────────────────

  Future<void> _updatePresence(bool online) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser.uid)
          .update({
        'online': online,
        'lastSeen': FieldValue.serverTimestamp(),
        'currentChat': online ? widget.chatId : null,
      });
      if (online) {
        _presenceTimer?.cancel();
        _presenceTimer =
            Timer.periodic(const Duration(seconds: 30), (_) {
          _updatePresence(true);
        });
      } else {
        _presenceTimer?.cancel();
      }
    } catch (_) {}
  }

  Future<void> _checkTogetherMessages() async {
    try {
      final friendDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.friendId)
          .get();
      if (!friendDoc.exists) return;
      final friendData = friendDoc.data() as Map<String, dynamic>;
      if (friendData['online'] != true ||
          friendData['currentChat'] != widget.chatId) return;
      final locked = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .where('lockType', isEqualTo: 'together')
          .where('unlocked', isEqualTo: false)
          .get();
      for (final doc in locked.docs) {
        await doc.reference.update({'unlocked': true});
      }
    } catch (_) {}
  }

  Future<void> _unlockDueMessages() async {
    try {
      final now = DateTime.now();
      final locked = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .where('timeLocked', isEqualTo: true)
          .where('unlocked', isEqualTo: false)
          .get();
      for (final doc in locked.docs) {
        final data = doc.data();
        final lockType = data['lockType'] as String? ?? 'datetime';
        if (lockType == 'together') continue;
        final unlockAt = data['unlockAt'] as Timestamp?;
        if (unlockAt == null) continue;
        if (unlockAt.toDate().isBefore(now)) {
          await doc.reference.update({'unlocked': true});
        }
      }
    } catch (_) {}
  }

  Future<void> _loadChatSettings() async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();
    if (doc.exists && mounted) {
      final data = doc.data() as Map<String, dynamic>;
      setState(() {
        _autoDeleteSeconds = data['autoDeleteSeconds'] ?? -1;
        _disappearingMode = data['disappearing24h'] == true;
      });
    }
  }

  // ── Screenshot detection ──────────────────────────────────────────────────

  void _listenForScreenshots() {
    try {
      _screenshotSub =
          _screenshotEventChannel.receiveBroadcastStream().listen((_) {
        _notifyScreenshot();
      });
    } catch (_) {}
  }

  Future<void> _notifyScreenshot() async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('events')
          .add({
        'type': 'screenshot',
        'by': _currentUser.uid,
        'timestamp': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📸 Screenshot detected'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {}
  }

  // ── Incoming messages / Morse notification ────────────────────────────────

  void _listenForIncomingMessages() {
    _messageListener = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      if (snapshot.docs.isEmpty) return;
      final doc = snapshot.docs.first;
      final data = doc.data();

      final senderId = data['senderId'] as String? ?? '';
      if (senderId == _currentUser.uid) return;

      if (_lastKnownMessageId == null) {
        _lastKnownMessageId = doc.id;
        return;
      }
      if (doc.id == _lastKnownMessageId) return;
      _lastKnownMessageId = doc.id;

      final isTimeLocked =
          data['timeLocked'] == true && data['unlocked'] != true;
      if (isTimeLocked) return;

      try {
        final myDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser.uid)
            .get();
        final myData = myDoc.data() as Map<String, dynamic>?;
        final myCurrentChat = myData?['currentChat'];
        final myOnline = myData?['online'] == true;
        if (myOnline && myCurrentChat == widget.chatId) return;
      } catch (_) {}

      _pendingNotificationCount++;
      _notificationBatchTimer?.cancel();
      _notificationBatchTimer =
          Timer(const Duration(seconds: 2), () async {
        final count = _pendingNotificationCount;
        _pendingNotificationCount = 0;
        try {
          await _morseChannel.invokeMethod('showMorseNotification', {
            'senderName': '',
            'text': count > 1 ? '*$count new messages' : 'New message',
            'count': count,
          });
        } catch (_) {}
      });
    });
  }

  bool _markingAsSeen = false;
  Future<void> _markMessagesAsSeen() async {
    if (_markingAsSeen) return; // prevent overlapping calls
    _markingAsSeen = true;
    try {
      _checkTogetherMessages();
      _unlockDueMessages();
      if (_disappearingMode) _deleteExpiredMessages();
      final messages = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .where('senderId', isNotEqualTo: _currentUser.uid)
          .where('seen', isEqualTo: false)
          .get();
      for (final doc in messages.docs) {
        final data = doc.data();
        if (data['timeLocked'] == true && data['unlocked'] != true) continue;
        await doc.reference.update({
          'seen': true,
          'seenAt': FieldValue.serverTimestamp(),
        });
        if (_autoDeleteSeconds == 0) {
          await doc.reference.delete();
        } else if (_autoDeleteSeconds > 0) {
          Future.delayed(Duration(seconds: _autoDeleteSeconds), () async {
            try {
              await doc.reference.delete();
            } catch (_) {}
          });
        }
      }
    } catch (_) {}
    finally { _markingAsSeen = false; }
  }

  // ── Triple tap → gesture screen ───────────────────────────────────────────

  bool _navigatingToGesture = false;

  void _handleScreenTap(TapUpDetails details) {
    _handlePointerDown(details.globalPosition.dx,
        MediaQuery.of(context).size.width);
  }

  // Raw pointer version — works even when ListView absorbs gesture events
  void _handlePointerDown(double dx, double screenWidth) {
    // Ignore left/right edge zones (Android back/forward gestures)
    if (dx < 30 || dx > screenWidth - 30) return;

    final now = DateTime.now();
    if (_lastTapTime == null ||
        now.difference(_lastTapTime!) > const Duration(milliseconds: 500)) {
      _tapCount = 1;
    } else {
      _tapCount++;
    }
    _lastTapTime = now;

    if (_tapCount >= 3) {
      _tapCount = 0;
      if (_navigatingToGesture) return;
      _navigatingToGesture = true;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HandGestureScreen(
            chatId: widget.chatId,
            friendName: widget.friendName,
          ),
        ),
      ).whenComplete(() => _navigatingToGesture = false);
    }
  }

  // ── Edit message ──────────────────────────────────────────────────────────

  void _startEdit(String messageId, String currentText) {
    setState(() {
      _editingMessageId = messageId;
      _isEditing = true;
      _messageController.text = currentText;
    });
    _focusNode.requestFocus();
    _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: currentText.length));
  }

  void _cancelEdit() {
    setState(() {
      _editingMessageId = null;
      _isEditing = false;
      _messageController.clear();
    });
    _focusNode.unfocus();
  }

  Future<void> _saveEdit() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _editingMessageId == null) return;
    _messageController.clear();
    final msgId = _editingMessageId!;
    setState(() {
      _editingMessageId = null;
      _isEditing = false;
    });

    try {
      String textToSave = text;
      bool isEncrypted = false;
      if (_e2eeReady) {
        try {
          textToSave =
              await _e2ee.encryptMessage(text, widget.friendId);
          isEncrypted = _e2ee.isEncrypted(textToSave);
        } catch (_) {}
      }

      // Invalidate cache so re-decryption happens on next display
      _decryptedCache.remove(msgId);

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc(msgId)
          .update({
        'text': textToSave,
        'encrypted': isEncrypted,
        'edited': true,
        'editedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  void _showDeleteDialog(String messageId, bool isMe) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Delete Message',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete for me',
                  style: TextStyle(fontSize: 16)),
              subtitle: const Text('Only removed from your screen'),
              onTap: () {
                Navigator.pop(context);
                _deleteForMe(messageId);
              },
            ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_forever,
                    color: Colors.red),
                title: const Text('Delete for everyone',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                subtitle: const Text('Removed from both devices'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteForEveryone(messageId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close, color: Colors.grey),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteForMe(String messageId) async {
    _decryptedCache.remove(messageId);
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(messageId)
        .update({'deletedFor.${_currentUser.uid}': true});
  }

  Future<void> _deleteForEveryone(String messageId) async {
    _decryptedCache.remove(messageId);
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(messageId)
        .update({
      'deletedForEveryone': true,
      'text': 'This message was deleted',
      'encrypted': false,
    });
  }

  // ── Reply ─────────────────────────────────────────────────────────────────

  void _setReply(Map<String, dynamic> msgData, String msgId) {
    setState(() {
      _replyToMessage = msgData;
      _replyToId = msgId;
    });
    _focusNode.requestFocus();
  }

  void _clearReply() {
    setState(() {
      _replyToMessage = null;
      _replyToId = null;
    });
  }

  // ── Send message ──────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    if (_isEditing) {
      await _saveEdit();
      return;
    }
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    _setTyping(false);
    _typingTimer?.cancel();
    _isTyping = false;

    final replyData = _replyToMessage != null
        ? {
            'replyToId': _replyToId,
            'replyText': _replyToMessage!['text'] ?? '',
            'replySenderId': _replyToMessage!['senderId'] ?? '',
          }
        : null;
    _clearReply();

    // Encrypt before storing in Firestore
    String textToStore = text;
    bool isEncrypted = false;
    if (_e2eeReady) {
      try {
        textToStore =
            await _e2ee.encryptMessage(text, widget.friendId);
        isEncrypted = _e2ee.isEncrypted(textToStore);
      } catch (_) {
        // fallback: send as plaintext
      }
    }

    try {
      final msgRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'text': textToStore,
        'encrypted': isEncrypted,
        'senderId': _currentUser.uid,
        'timestamp': FieldValue.serverTimestamp(),
        'saved': false,
        'seen': false,
        'seenAt': null,
        'reactions': {},
        'autoDeleteSeconds': _autoDeleteSeconds,
        'timeLocked': false,
        'deletedForEveryone': false,
        'deletedFor': {},
        'edited': false,
        if (replyData != null) ...replyData,
      });

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update({
        'lastMessage':
            isEncrypted ? '🔐 Encrypted message' : text,
        'lastMessageTime': FieldValue.serverTimestamp(),
      });



      if (_disappearingMode) {
        Future.delayed(const Duration(hours: 24), () async {
          try {
            await msgRef.delete();
          } catch (_) {}
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // ── Save / Reactions ──────────────────────────────────────────────────────

  Future<void> _toggleSave(String messageId, bool isSaved) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(messageId)
        .update({'saved': !isSaved});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(!isSaved ? 'Message saved ⭐' : 'Unsaved'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _addReaction(String messageId, String emoji) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(messageId)
        .update({'reactions.${_currentUser.uid}': emoji});
  }

  // ── Message options bottom sheet ──────────────────────────────────────────

  void _showMessageOptions(
      String messageId, bool isMe, Map<String, dynamic> msgData,
      {String? decryptedText}) {
    final timestamp = msgData['timestamp'] as Timestamp?;
    final canEdit = isMe &&
        timestamp != null &&
        DateTime.now()
                .difference(timestamp.toDate())
                .inMinutes <
            5 &&
        msgData['deletedForEveryone'] != true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 12, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _emojis.map((emoji) {
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _addReaction(messageId, emoji);
                    },
                    child: Text(emoji,
                        style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.reply, color: Colors.blue),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                final displayData =
                    Map<String, dynamic>.from(msgData);
                if (decryptedText != null) {
                  displayData['text'] = decryptedText;
                }
                _setReply(displayData, messageId);
              },
            ),
            if (canEdit)
              ListTile(
                leading:
                    const Icon(Icons.edit, color: Colors.blue),
                title: const Text('Edit'),
                subtitle: const Text('Within 5 minutes'),
                onTap: () {
                  Navigator.pop(context);
                  // Always edit with the decrypted text
                  _startEdit(messageId,
                      decryptedText ?? msgData['text'] ?? '');
                },
              ),
            ListTile(
              leading: Icon(
                msgData['saved'] == true
                    ? Icons.star
                    : Icons.star_border,
                color: Colors.amber,
              ),
              title: Text(
                  msgData['saved'] == true ? 'Unsave' : 'Save ⭐'),
              onTap: () {
                Navigator.pop(context);
                _toggleSave(messageId, msgData['saved'] == true);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.copy, color: Colors.grey),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(context);
                // Copy decrypted text, never raw ciphertext
                Clipboard.setData(ClipboardData(
                    text: decryptedText ??
                        msgData['text'] ??
                        ''));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Colors.red),
              title: const Text('Delete',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteDialog(messageId, isMe);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _getDisplayTime(Map<String, dynamic> msgData) {
    final lockType = msgData['lockType'] as String?;
    final timeLocked = msgData['timeLocked'] == true;
    if (timeLocked &&
        (lockType == 'datetime' || lockType == 'duration')) {
      final unlockAt = msgData['unlockAt'] as Timestamp?;
      if (unlockAt != null) {
        return unlockAt.toDate().toString().substring(11, 16);
      }
    }
    final timestamp = msgData['timestamp'] as Timestamp?;
    if (timestamp != null) {
      return timestamp.toDate().toString().substring(11, 16);
    }
    return '';
  }

  Widget _buildReadReceipt(Map<String, dynamic> msgData) {
    final seen = msgData['seen'] == true;
    final timestamp = msgData['timestamp'];
    final delivered = timestamp != null;
    if (seen) {
      return Icon(Icons.done_all, size: 14, color: Colors.blue[300]);
    } else if (delivered) {
      return const Icon(Icons.done_all,
          size: 14, color: Colors.white60);
    } else {
      return const Icon(Icons.done, size: 14, color: Colors.white60);
    }
  }

  // ── Sub-widgets ───────────────────────────────────────────────────────────

  Widget _buildLockedBubble(Map<String, dynamic> msgData, bool isMe) {
    return Container(
      margin:
          const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75),
      decoration: BoxDecoration(
        color: isMe ? Colors.blue[800] : Colors.grey[350],
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: Border.all(
            color: isMe ? Colors.blue[300]! : Colors.grey[400]!,
            width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🔒', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Opens when both online',
                  style: TextStyle(
                      color: isMe ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Be online together to reveal',
              style: TextStyle(
                  color:
                      isMe ? Colors.blue[200] : Colors.grey[600],
                  fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildReplyPreview(
      Map<String, dynamic> msgData, bool isMe) {
    final replyText = msgData['replyText'] as String? ?? '';
    final replySenderId =
        msgData['replySenderId'] as String? ?? '';
    final isReplyMe = replySenderId == _currentUser.uid;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.blue[700]!.withOpacity(0.5)
            : Colors.grey[400]!.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
              color: isMe ? Colors.white54 : Colors.blue,
              width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isReplyMe ? 'You' : widget.friendName,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11,
                color:
                    isMe ? Colors.white70 : Colors.blue[700]),
          ),
          const SizedBox(height: 2),
          Text(
            replyText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                color: isMe
                    ? Colors.white60
                    : Colors.black54),
          ),
        ],
      ),
    );
  }

  // ── Message bubble (FutureBuilder for async decrypt) ──────────────────────

  Widget _buildMessageItem(
      QueryDocumentSnapshot msgDoc, bool isMe) {
    final msgData = msgDoc.data() as Map<String, dynamic>;
    final isSaved = msgData['saved'] == true;
    final hasReply = msgData['replyToId'] != null;
    final reactions =
        (msgData['reactions'] as Map<dynamic, dynamic>?) ?? {};
    final lockType =
        msgData['lockType'] as String? ?? 'datetime';
    final deletedFor =
        (msgData['deletedFor'] as Map<dynamic, dynamic>?) ?? {};
    final isDeletedForMe =
        deletedFor[_currentUser.uid] == true;
    final isDeletedForEveryone =
        msgData['deletedForEveryone'] == true;
    final isEdited = msgData['edited'] == true;
    final rawText = msgData['text'] as String? ?? '';

    bool isTimeLocked =
        msgData['timeLocked'] == true &&
            msgData['unlocked'] != true;
    if (isTimeLocked && lockType != 'together') {
      final unlockAt = msgData['unlockAt'] as Timestamp?;
      if (unlockAt != null &&
          unlockAt.toDate().isBefore(DateTime.now())) {
        isTimeLocked = false;
        Future.microtask(() => _unlockDueMessages());
      }
    }

    if (isDeletedForMe) return const SizedBox.shrink();
    if (isTimeLocked && lockType != 'together') {
      return const SizedBox.shrink();
    }

    return FutureBuilder<String>(
      // Use cache as initialData → no flicker on list rebuilds
      future: isDeletedForEveryone
          ? Future.value(rawText)
          : _decryptText(msgDoc.id, rawText),
      initialData: _decryptedCache[msgDoc.id] ?? rawText,
      builder: (context, snapshot) {
        final displayText = snapshot.data ??
            (isDeletedForEveryone ? rawText : '...');

        return Dismissible(
          key: ValueKey(msgDoc.id),
          direction: DismissDirection.startToEnd,
          confirmDismiss: (_) async {
            if (!isTimeLocked && !isDeletedForEveryone) {
              HapticFeedback.lightImpact();
              final displayData =
                  Map<String, dynamic>.from(msgData);
              displayData['text'] = displayText;
              _setReply(displayData, msgDoc.id);
            }
            return false;
          },
          background: Align(
            alignment: isMe
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 12,
                  right: isMe ? 12 : 0),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle),
                child: const Icon(Icons.reply,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
          child: GestureDetector(
            onLongPress: isTimeLocked || isDeletedForEveryone
                ? null
                : () => _showMessageOptions(
                      msgDoc.id,
                      isMe,
                      msgData,
                      decryptedText: displayText,
                    ),
            onDoubleTap: isTimeLocked || isDeletedForEveryone
                ? null
                : () => _toggleSave(msgDoc.id, isSaved),
            child: Align(
              alignment: isMe
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  isTimeLocked
                      ? _buildLockedBubble(msgData, isMe)
                      : Container(
                          margin: const EdgeInsets.symmetric(
                              vertical: 3, horizontal: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context)
                                          .size
                                          .width *
                                      0.75),
                          decoration: BoxDecoration(
                            color: isDeletedForEveryone
                                ? Colors.grey[300]
                                : isMe
                                    ? Colors.blue
                                    : Colors.grey[200],
                            borderRadius: BorderRadius.only(
                              topLeft:
                                  const Radius.circular(16),
                              topRight:
                                  const Radius.circular(16),
                              bottomLeft: Radius.circular(
                                  isMe ? 16 : 4),
                              bottomRight: Radius.circular(
                                  isMe ? 4 : 16),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                  color: Colors.black12,
                                  blurRadius: 4,
                                  offset: Offset(0, 2))
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.end,
                            children: [
                              if (hasReply &&
                                  !isDeletedForEveryone)
                                _buildReplyPreview(
                                    msgData, isMe),
                              Row(
                                mainAxisSize:
                                    MainAxisSize.min,
                                children: [
                                  // 🔐 E2EE badge per bubble
                                  if (msgData['encrypted'] ==
                                          true &&
                                      !isDeletedForEveryone) ...[
                                    Text(
                                      '🔐',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: isMe
                                              ? Colors
                                                  .white54
                                              : Colors
                                                  .black38),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      isDeletedForEveryone
                                          ? '🚫 This message was deleted'
                                          : displayText,
                                      style: TextStyle(
                                        color: isDeletedForEveryone
                                            ? Colors.grey[600]
                                            : isMe
                                                ? Colors.white
                                                : Colors
                                                    .black87,
                                        fontSize: 15,
                                        fontStyle: isDeletedForEveryone
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize:
                                    MainAxisSize.min,
                                children: [
                                  if (isEdited &&
                                      !isDeletedForEveryone) ...[
                                    Text(
                                      'edited ',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isMe
                                            ? Colors.white38
                                            : Colors.black26,
                                        fontStyle:
                                            FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                  Text(
                                    _getDisplayTime(msgData),
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isMe
                                            ? Colors.white60
                                            : Colors.black45),
                                  ),
                                  if (!isDeletedForEveryone &&
                                      isSaved) ...[
                                    const SizedBox(width: 4),
                                    const Text('⭐',
                                        style: TextStyle(
                                            fontSize: 10)),
                                  ],
                                  if (isMe &&
                                      !isDeletedForEveryone) ...[
                                    const SizedBox(width: 4),
                                    _buildReadReceipt(msgData),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                  if (!isTimeLocked &&
                      !isDeletedForEveryone &&
                      reactions.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                          left: isMe ? 0 : 16,
                          right: isMe ? 16 : 0,
                          bottom: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius:
                              BorderRadius.circular(12),
                          border: Border.all(
                              color: Colors.grey[300]!),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black12,
                                blurRadius: 4)
                          ],
                        ),
                        child: Text(
                            reactions.values
                                .toSet()
                                .join(' '),
                            style: const TextStyle(
                                fontSize: 16)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final statusText = _friendStatusText();

    return PanicDetector(
      child: Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(widget.friendName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(width: 6),
                // Live E2EE lock icon
                Tooltip(
                  message: _e2eeReady
                      ? 'End-to-end encrypted'
                      : 'Setting up encryption...',
                  child: Icon(
                    _e2eeReady
                        ? Icons.lock
                        : Icons.lock_open,
                    size: 14,
                    color: _e2eeReady
                        ? Colors.greenAccent
                        : Colors.white38,
                  ),
                ),
              ],
            ),
            if (statusText.isNotEmpty)
              Text(
                statusText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: _friendTyping
                      ? Colors.green[300]
                      : _friendOnline
                          ? Colors.green[200]
                          : Colors.white60,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _disappearingMode
                  ? Icons.timer
                  : Icons.timer_off_outlined,
              color:
                  _disappearingMode ? Colors.orange : null,
            ),
            tooltip: _disappearingMode
                ? 'Disappearing ON (24h)'
                : 'Disappearing OFF',
            onPressed: _toggleDisappearing,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatSettingsScreen(
                    chatId: widget.chatId,
                    friendName: widget.friendName,
                  ),
                ),
              );
              _loadChatSettings();
            },
          ),
        ],
      ),
      body: TwoFingerLongPressWrapper(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            // Only single-finger taps count
            if (e.pointer != e.pointer) return;
            _handlePointerDown(e.position.dx, MediaQuery.of(context).size.width);
          },
          child: Column(
          children: [
            // E2EE initialising banner
            if (!_e2eeReady)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                color: Colors.blue[900],
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: const [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white70),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Setting up end-to-end encryption...',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white70),
                    ),
                  ],
                ),
              ),

            // Disappearing mode banner
            if (_disappearingMode)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                color: Colors.orange[50],
                child: Row(
                  children: [
                    Icon(Icons.timer,
                        size: 14,
                        color: Colors.orange[700]),
                    const SizedBox(width: 6),
                    Text(
                      'Disappearing messages • 24 hours',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange[700],
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: RepaintBoundary(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('chats')
                    .doc(widget.chatId)
                    .collection('messages')
                    .orderBy('timestamp', descending: true)
                    .limit(50)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                          ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(
                        child:
                            CircularProgressIndicator());
                  }
                  if (!snapshot.hasData ||
                      snapshot.data!.docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [
                          const Icon(
                              Icons.chat_bubble_outline,
                              size: 48,
                              color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(
                              'Say hi to ${widget.friendName}! 👋',
                              style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16)),
                          const SizedBox(height: 6),
                          const Row(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock,
                                  size: 12,
                                  color: Colors.grey),
                              SizedBox(width: 4),
                              Text(
                                'End-to-end encrypted',
                                style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }

                  // Throttle: mark-as-seen runs at most once per second
                  // to avoid Firestore spam on every Firestore snapshot
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) {
                    final now = DateTime.now();
                    if (_lastSeenCheck == null ||
                        now.difference(_lastSeenCheck!) >
                            const Duration(seconds: 1)) {
                      _lastSeenCheck = now;
                      _markMessagesAsSeen();
                    }
                  });

                  // Wait for E2EE keys before showing messages
                  // Prevents [Unable to decrypt] race condition on open
                  if (!_e2eeReady) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                          SizedBox(height: 12),
                          Text('Loading messages...',
                              style: TextStyle(color: Colors.grey, fontSize: 13)),
                        ],
                      ),
                    );
                  }

                  final docs = snapshot.data?.docs ?? [];
                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    cacheExtent: 500,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 12),
                    physics: const ClampingScrollPhysics(),
                    primary: false,
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final msgDoc = docs[index];
                      final msgData = msgDoc.data()
                          as Map<String, dynamic>;
                      final isMe = msgData['senderId'] ==
                          _currentUser.uid;
                      return _buildMessageItem(
                          msgDoc, isMe);
                    },
                  );
                },
              ),
              ), // RepaintBoundary
            ),

            // Reply banner
            if (_replyToMessage != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border(
                      top: BorderSide(
                          color: Colors.blue[100]!)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 40,
                      color: Colors.blue,
                      margin:
                          const EdgeInsets.only(right: 10),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            _replyToMessage!['senderId'] ==
                                    _currentUser.uid
                                ? 'Replying to yourself'
                                : 'Replying to ${widget.friendName}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                                fontSize: 12),
                          ),
                          Text(
                            _replyToMessage!['text'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Colors.grey),
                      onPressed: _clearReply,
                    ),
                  ],
                ),
              ),

            // Edit banner
            if (_isEditing)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber[50],
                  border: Border(
                      top: BorderSide(
                          color: Colors.amber[200]!)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 32,
                      color: Colors.amber[700],
                      margin:
                          const EdgeInsets.only(right: 10),
                    ),
                    const Icon(Icons.edit,
                        size: 16, color: Colors.amber),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Editing message',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                            fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Colors.grey),
                      onPressed: _cancelEdit,
                    ),
                  ],
                ),
              ),

            // Input bar — isolated widget so typing never rebuilds message list
            _MessageInputBar(
              controller: _messageController,
              focusNode: _focusNode,
              isEditing: _isEditing,
              e2eeReady: _e2eeReady,
              onSend: _sendMessage,
              onCancelEdit: _cancelEdit,
              onChanged: _onTextChanged,
              onTimeLock: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TimeLockedMessageScreen(
                    chatId: widget.chatId,
                    friendId: widget.friendId,
                    friendName: widget.friendName,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ), // TwoFingerLongPressWrapper
      ), // PanicDetector
    );
  }
}

// ── Isolated message input bar ────────────────────────────────────────────────
// Kept as a separate StatefulWidget so typing never triggers a rebuild
// of the message list or any other part of ChatScreen.
class _MessageInputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isEditing;
  final bool e2eeReady;
  final VoidCallback onSend;
  final VoidCallback onCancelEdit;
  final VoidCallback onTimeLock;
  final void Function(String) onChanged;

  const _MessageInputBar({
    required this.controller,
    required this.focusNode,
    required this.isEditing,
    required this.e2eeReady,
    required this.onSend,
    required this.onCancelEdit,
    required this.onTimeLock,
    required this.onChanged,
  });

  @override
  State<_MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<_MessageInputBar> {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
        ],
      ),
      child: Row(
        children: [
          if (!widget.isEditing)
            IconButton(
              icon: const Text('🔒', style: TextStyle(fontSize: 22)),
              onPressed: widget.onTimeLock,
            ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              textCapitalization: TextCapitalization.sentences,
              maxLines: null,
              onChanged: widget.onChanged,
              decoration: InputDecoration(
                hintText: widget.isEditing
                    ? 'Edit message...'
                    : 'Message...',
                filled: true,
                fillColor: widget.isEditing ? Colors.amber[50] : Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                suffixIcon: widget.e2eeReady
                    ? const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(Icons.lock, size: 14, color: Colors.green),
                      )
                    : null,
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 24, minHeight: 24),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: widget.onSend,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: widget.isEditing ? Colors.amber[700] : Colors.blue,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.isEditing ? Icons.check : Icons.send,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}