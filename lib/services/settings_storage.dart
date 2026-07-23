import 'package:shared_preferences/shared_preferences.dart';

class SettingsStorage {
  // 保存するときに使用する名前
  static const String _deviceNameKey = 'device_name';
  static const String _nicknameKey = 'nickname';

  /// 端末名とニックネームを保存する
  static Future<void> saveSettings({
    required String deviceName,
    required String nickname,
  }) async {
    final SharedPreferences prefs =
    await SharedPreferences.getInstance();

    await prefs.setString(_deviceNameKey, deviceName);
    await prefs.setString(_nicknameKey, nickname);
  }

  /// 保存されている端末名を読み込む
  static Future<String> loadDeviceName() async {
    final SharedPreferences prefs =
    await SharedPreferences.getInstance();

    return prefs.getString(_deviceNameKey) ?? '';
  }

  /// 保存されているニックネームを読み込む
  static Future<String> loadNickname() async {
    final SharedPreferences prefs =
    await SharedPreferences.getInstance();

    return prefs.getString(_nicknameKey) ?? '';
  }

  /// 保存内容を削除する
  static Future<void> clearSettings() async {
    final SharedPreferences prefs =
    await SharedPreferences.getInstance();

    await prefs.remove(_deviceNameKey);
    await prefs.remove(_nicknameKey);
  }
}