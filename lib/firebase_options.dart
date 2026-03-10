import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAGhPKOsYs-IEYie2rwfmdoYY2cw0T_-uQ',
    appId: '1:818486297800:android:c9b803d53d899a2e2d91fd',
    messagingSenderId: '818486297800',
    projectId: 'us-messenger',
    storageBucket: 'us-messenger.firebasestorage.app',
  );

  static FirebaseOptions get currentPlatform {
    return android;
  }
}