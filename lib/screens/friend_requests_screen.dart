import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FriendRequestsScreen extends StatelessWidget {
  const FriendRequestsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friend Requests'),
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('friendRequests')
            .where('to', isEqualTo: currentUser!.uid)
            .where('status', isEqualTo: 'pending')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person_add_disabled, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No pending requests',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final requestDoc = snapshot.data!.docs[index];
              final requestData = requestDoc.data() as Map<String, dynamic>;
              final fromId = requestData['from'] as String;

              return FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance
                    .collection('users')
                    .doc(fromId)
                    .get(),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) return const SizedBox.shrink();
                  final rawData = userSnapshot.data!.data();
                  if (rawData == null) return const SizedBox.shrink();
                  final userData = rawData as Map<String, dynamic>;
                  final name = userData['name'] ?? 'Unknown';
                  final email = userData['email'] ?? '';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.blue,
                            radius: 24,
                            child: Text(
                              name[0].toUpperCase(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                Text(email,
                                    style: TextStyle(
                                        color: Colors.grey[600], fontSize: 13)),
                              ],
                            ),
                          ),
                          // Accept button
                          ElevatedButton(
                            onPressed: () => _acceptRequest(
                                context, requestDoc.id, fromId,
                                currentUser.uid, name),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              shape: const CircleBorder(),
                              padding: const EdgeInsets.all(12),
                            ),
                            child: const Icon(Icons.check,
                                color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 8),
                          // Reject button
                          ElevatedButton(
                            onPressed: () =>
                                _rejectRequest(context, requestDoc.id),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              shape: const CircleBorder(),
                              padding: const EdgeInsets.all(12),
                            ),
                            child: const Icon(Icons.close,
                                color: Colors.white, size: 20),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _acceptRequest(BuildContext context, String requestId,
      String fromId, String toId, String fromName) async {
    try {
      final participants = [fromId, toId]..sort();
      final chatId = participants.join('_');

      await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
        'participants': participants,
        'lastMessage': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'autoDeleteSeconds': -1,
      }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('friendRequests')
          .doc(requestId)
          .update({'status': 'accepted'});

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$fromName added as friend ✅'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _rejectRequest(
      BuildContext context, String requestId) async {
    await FirebaseFirestore.instance
        .collection('friendRequests')
        .doc(requestId)
        .update({'status': 'rejected'});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Request rejected')),
    );
  }
}
