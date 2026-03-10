import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'thumb_gesture_screen.dart';
import 'friend_requests_screen.dart';
import 'sad_face_screen.dart';
import 'panic_detector.dart';
import 'two_finger_long_press_wrapper.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({Key? key}) : super(key: key);

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final _currentUser = FirebaseAuth.instance.currentUser!;
  bool _isSearching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final Map<String, String> _nicknames = {};
  final Map<String, Map<String, dynamic>> _friendCache = {};


  @override
  void initState() {
    super.initState();
    _loadNicknames();
  }


  Future<void> _loadNicknames() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser.uid)
          .get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        final nicknames =
            data['nicknames'] as Map<String, dynamic>? ?? {};
        setState(() {
          _nicknames.clear();
          nicknames.forEach((k, v) => _nicknames[k] = v.toString());
        });
      }
    } catch (_) {}
  }

  String _displayName(String friendId, String realName) =>
      _nicknames[friendId] ?? realName;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Send friend request ───────────────────────────────────────────────────

  Future<void> _sendFriendRequest(String email) async {
    if (email.trim().isEmpty) return;
    if (email.trim().toLowerCase() ==
        _currentUser.email?.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You can't add yourself!")),
      );
      return;
    }

    try {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: email.trim().toLowerCase())
          .get();

      if (query.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User not found')),
          );
        }
        return;
      }

      final toUser = query.docs.first;
      final toId = toUser.id;

      final existing = await FirebaseFirestore.instance
          .collection('friendRequests')
          .where('from', isEqualTo: _currentUser.uid)
          .where('to', isEqualTo: toId)
          .where('status', isEqualTo: 'pending')
          .get();

      if (existing.docs.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request already sent!')),
          );
        }
        return;
      }

      final participants = [_currentUser.uid, toId]..sort();
      final chatId = participants.join('_');
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .get();

      if (chatDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already friends!')),
          );
        }
        return;
      }

      await FirebaseFirestore.instance
          .collection('friendRequests')
          .add({
        'from': _currentUser.uid,
        'to': toId,
        'fromEmail': _currentUser.email,
        'fromName':
            _currentUser.displayName ?? _currentUser.email,
        'status': 'pending',
        'timestamp': FieldValue.serverTimestamp(),
      });

      final name =
          (toUser.data() as Map<String, dynamic>)['name'] ?? email;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Friend request sent to $name ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _showAddFriendDialog() {
    final emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send Friend Request'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter email address',
            prefixIcon: Icon(Icons.email),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _sendFriendRequest(emailController.text);
            },
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
  }

  // ── Rename friend ─────────────────────────────────────────────────────────

  void _showRenameDialog(String friendId, String currentDisplayName) {
    final controller =
        TextEditingController(text: currentDisplayName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Contact'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter nickname',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          if (_nicknames.containsKey(friendId))
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _saveNickname(friendId, null);
              },
              child: const Text('Remove Nickname',
                  style: TextStyle(color: Colors.red)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await _saveNickname(friendId, newName);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveNickname(String friendId, String? nickname) async {
    try {
      if (nickname == null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser.uid)
            .update(
                {'nicknames.$friendId': FieldValue.delete()});
        setState(() => _nicknames.remove(friendId));
      } else {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser.uid)
            .update({'nicknames.$friendId': nickname});
        setState(() => _nicknames[friendId] = nickname);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(nickname == null
                ? 'Nickname removed'
                : 'Renamed to "$nickname"'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {}
  }

  // ── Delete chat ───────────────────────────────────────────────────────────

  Future<void> _deleteChat(String chatId) async {
    try {
      final messages = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .get();
      for (final doc in messages.docs) {
        await doc.reference.delete();
      }
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chat deleted.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<bool> _confirmDelete(String friendName) async {
    bool confirm = false;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Chat'),
        content: Text(
          'Clear all messages with $friendName?\n\nThey will stay in your chat list and you can message them again.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              confirm = false;
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              confirm = true;
              Navigator.pop(ctx);
            },
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return confirm;
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  Future<void> _logout() async {
    // Delete FCM token so this device stops receiving notifications after logout
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const SadFaceScreen()),
        (route) => false,
      );
    }
  }

  // ── Search ────────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  // ── Chat options ──────────────────────────────────────────────────────────

  void _showChatOptions(
      String chatId, String friendId, String displayName) {
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
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Text(displayName[0].toUpperCase(),
                        style:
                            const TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(width: 12),
                  Text(displayName,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.blue),
              title: const Text('Rename'),
              subtitle: const Text('Only visible to you'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(friendId, displayName);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Colors.red),
              title: const Text('Delete Chat',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context);
                final confirmed = await _confirmDelete(displayName);
                if (confirmed) _deleteChat(chatId);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Search results ────────────────────────────────────────────────────────

  Widget _buildSearchResults() {
    return FutureBuilder<QuerySnapshot>(
      future: FirebaseFirestore.instance
          .collection('users')
          .where('email', isNotEqualTo: _currentUser.email)
          .get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final allUsers = snapshot.data!.docs
            .map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return {
                'uid': doc.id,
                'name': data['name'] ?? 'Unknown',
                'email': data['email'] ?? '',
              };
            })
            .where((u) {
              final name = (u['name'] as String).toLowerCase();
              final email = (u['email'] as String).toLowerCase();
              final nickname =
                  (_nicknames[u['uid']] ?? '').toLowerCase();
              return name.contains(_searchQuery) ||
                  email.contains(_searchQuery) ||
                  nickname.contains(_searchQuery);
            })
            .toList();

        if (allUsers.isEmpty) {
          return Center(
            child: Text(
              'No results for "$_searchQuery"',
              style: const TextStyle(color: Colors.grey),
            ),
          );
        }

        return ListView.builder(
          itemCount: allUsers.length,
          itemBuilder: (context, index) {
            final user = allUsers[index];
            final displayName =
                _displayName(user['uid']!, user['name']!);
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.blue,
                child: Text(
                  displayName[0].toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                ),
              ),
              title: Text(displayName,
                  style:
                      const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(user['email']!),
              onTap: () {
                setState(() {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                });
                _openOrCreateChat(user['uid']!, displayName);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _openOrCreateChat(
      String friendId, String friendName) async {
    final participants = [_currentUser.uid, friendId]..sort();
    final chatId = participants.join('_');
    final chatDoc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .get();

    if (!chatDoc.exists) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .set({
        'participants': participants,
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
      });
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ThumbGestureScreen(
            chatId: chatId,
            friendId: friendId,
            friendName: friendName,
          ),
        ),
      );
    }
  }

  // ── Friend cache ──────────────────────────────────────────────────────────

  Future<void> _prefetchFriend(String friendId) async {
    if (_friendCache.containsKey(friendId)) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(friendId)
          .get();
      if (doc.exists && mounted) {
        setState(() => _friendCache[friendId] =
            doc.data() as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  // ── Chat tile ─────────────────────────────────────────────────────────────

  Widget _buildChatTile({
    required QueryDocumentSnapshot chatDoc,
    required Map<String, dynamic> chatData,
    required String friendId,
    required Map<String, dynamic> friendData,
  }) {
    final realName = friendData['name'] as String? ?? 'Unknown';
    final friendName = _displayName(friendId, realName);

    if (_searchQuery.isNotEmpty &&
        !friendName.toLowerCase().contains(_searchQuery) &&
        !realName.toLowerCase().contains(_searchQuery)) {
      return const SizedBox.shrink();
    }

    return Dismissible(
      key: Key(chatDoc.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(friendName),
      onDismissed: (_) => _deleteChat(chatDoc.id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Colors.red,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete, color: Colors.white, size: 28),
            SizedBox(height: 4),
            Text('Delete',
                style:
                    TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .doc(chatDoc.id)
            .collection('messages')
            .where('senderId', isNotEqualTo: _currentUser.uid)
            .where('seen', isEqualTo: false)
            .snapshots(),
        builder: (context, unreadSnap) {
          final unreadCount = unreadSnap.data?.docs.length ?? 0;
          final timeStr = chatData['lastMessageTime'] != null
              ? (chatData['lastMessageTime'] as Timestamp)
                  .toDate()
                  .toString()
                  .substring(11, 16)
              : '';
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.blue,
              child: Text(
                friendName[0].toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold),
              ),
            ),
            title: Text(friendName,
                style: const TextStyle(
                    fontWeight: FontWeight.bold)),
            subtitle: Text(
              chatData['lastMessage'] ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: unreadCount > 0
                    ? FontWeight.w600
                    : FontWeight.normal,
                color: unreadCount > 0
                    ? Colors.black87
                    : Colors.grey[600],
              ),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: unreadCount > 0
                        ? Colors.green[600]
                        : Colors.grey,
                    fontWeight: unreadCount > 0
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (unreadCount > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(1),
                    constraints: const BoxConstraints(
                        minWidth: 20, minHeight: 20),
                    decoration: const BoxDecoration(
                      color: Color(0xFF25D366),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unreadCount > 99
                          ? '99+'
                          : '$unreadCount',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ThumbGestureScreen(
                  chatId: chatDoc.id,
                  friendId: friendId,
                  friendName: friendName,
                ),
              ),
            ),
            onLongPress: () =>
                _showChatOptions(chatDoc.id, friendId, friendName),
          );
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PanicDetector(
      child: TwoFingerLongPressWrapper(
        child: Scaffold(
        appBar: AppBar(
          title: _isSearching
              ? Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search chats...',
                      hintStyle: TextStyle(color: Colors.black45),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 10),
                    ),
                    style: const TextStyle(
                        color: Colors.black, fontSize: 16),
                    onChanged: (val) => setState(
                        () => _searchQuery = val.toLowerCase()),
                  ),
                )
              : const Text('us',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 22)),
          centerTitle: !_isSearching,
          actions: [
            IconButton(
              icon:
                  Icon(_isSearching ? Icons.close : Icons.search),
              onPressed: _toggleSearch,
            ),
            if (!_isSearching)
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('friendRequests')
                    .where('to', isEqualTo: _currentUser.uid)
                    .where('status', isEqualTo: 'pending')
                    .snapshots(),
                builder: (context, snapshot) {
                  final count = snapshot.data?.docs.length ?? 0;
                  return Stack(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.notifications),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  const FriendRequestsScreen()),
                        ),
                      ),
                      if (count > 0)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                                minWidth: 16, minHeight: 16),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            if (!_isSearching)
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: _logout,
              ),
          ],
        ),
        body: _isSearching && _searchQuery.isNotEmpty
            ? _buildSearchResults()
            : StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('chats')
                    .where('participants',
                        arrayContains: _currentUser.uid)
                    .orderBy('lastMessageTime', descending: true)
                    .snapshots(includeMetadataChanges: false),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }

                  if (!snapshot.hasData ||
                      snapshot.data!.docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.chat_bubble_outline,
                              size: 80, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text('No chats yet',
                              style: TextStyle(
                                  fontSize: 18,
                                  color: Colors.grey)),
                          const SizedBox(height: 8),
                          const Text(
                              'Send a friend request to start chatting',
                              style:
                                  TextStyle(color: Colors.grey)),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _showAddFriendDialog,
                            icon: const Icon(Icons.person_add),
                            label: const Text('Add Friend'),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, index) {
                      final chatDoc = snapshot.data!.docs[index];
                      final chatData =
                          chatDoc.data() as Map<String, dynamic>;
                      final participants = List<String>.from(
                          chatData['participants']);
                      final friendId = participants.firstWhere(
                          (id) => id != _currentUser.uid);

                      if (_friendCache.containsKey(friendId)) {
                        return _buildChatTile(
                          chatDoc: chatDoc,
                          chatData: chatData,
                          friendId: friendId,
                          friendData: _friendCache[friendId]!,
                        );
                      }

                      _prefetchFriend(friendId);
                      return const SizedBox(
                        height: 72,
                        child: ListTile(
                          leading: CircleAvatar(
                              backgroundColor:
                                  Color(0xFFE8E8E8)),
                          title: SizedBox(
                            height: 10,
                            child: ColoredBox(
                                color: Color(0xFFE8E8E8)),
                          ),
                          subtitle: SizedBox(
                            height: 8,
                            child: ColoredBox(
                                color: Color(0xFFF0F0F0)),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
        floatingActionButton: FloatingActionButton(
          onPressed: _showAddFriendDialog,
          tooltip: 'Add Friend',
          child: const Icon(Icons.person_add),
        ),
      ),
    ),
    );
  }
}