import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

class FirebaseService {
  FirebaseService._();

  // アプリ全体で共有するFirebaseService
  static final FirebaseService _instance = FirebaseService._();

  // ============================================================
  // Firebase
  // ============================================================

  /// Firebaseを初期化する。
  static Future<void> initialize() {
    return Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 15));
  }

  /// Firebase Authenticationで匿名ログインする。
  static Future<User?> signInAnonymously() async {
    final credential = await FirebaseAuth.instance.signInAnonymously().timeout(
      const Duration(seconds: 15),
    );

    return credential.user;
  }

  /// 現在ログインしているユーザーを取得する。
  static User? get currentUser => FirebaseAuth.instance.currentUser;

  /// 現在ログインしているユーザーのUIDを取得する。
  static String? get userId => FirebaseAuth.instance.currentUser?.uid;

  /// ログアウトする。
  static Future<void> signOut() {
    return FirebaseAuth.instance.signOut();
  }

  // ============================================================
  // Analytics
  // ============================================================

  /// AnalyticsにユーザーIDを設定する。
  static Future<void> setUserId(String? userId) {
    return FirebaseAnalytics.instance.setUserId(id: userId);
  }

  /// 汎用的なイベントを送信する。
  static Future<void> logEvent({
    required String name,
    Map<String, Object?>? parameters,
  }) async {
    final nonNullParameters = <String, Object>{};

    parameters?.forEach((key, value) {
      if (value == null) return;

      // Firebase Analytics のイベントパラメータでは bool を直接送れないため文字列化する。
      if (value is bool) {
        nonNullParameters[key] = value ? 'true' : 'false';
      } else {
        nonNullParameters[key] = value;
      }
    });

    // ログ送信失敗でアプリ本体の処理を失敗させない。
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: name,
        parameters: nonNullParameters,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FIREBASE] logEvent failed: $name $e');
      }
    }
  }
}

