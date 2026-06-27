import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:intl/intl.dart' show DateFormat;
import '../ble/nickname.dart';

// The callback function should always be a top-level or static function.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(KeyManagementTaskHandler());
}

class KeyManagementTaskHandler extends TaskHandler {
  final _ble = BleNickname();

  // Called when the task is started.
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (kDebugMode) debugPrint('KMTaskHandler onStart(starter: ${starter.name})');
    // WidgetsFlutterBinding.ensureInitialized(); // (J9110) BLEのJNIを繋ぐ（Tried to send a platform message to Flutter, but FlutterJNI was detached from native C++）
    DartPluginRegistrant.ensureInitialized(); // BLEのJNIを繋ぐ（Tried to send a platform message to Flutter, but FlutterJNI was detached from native C++）
    await _ble.startExchange();
  }

  // Called based on the eventAction set in ForegroundTaskOptions.
  @override
  void onRepeatEvent(DateTime timestamp) {
    // Send data to main isolate.
    final Map<String, dynamic> data = {
      "timestampMillis": timestamp.millisecondsSinceEpoch,
    };
    FlutterForegroundTask.sendDataToMain(data);
  }

  // Called when the task is destroyed.
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    if (kDebugMode) debugPrint('KMTaskHandler onDestroy(isTimeout: $isTimeout)');
    await _ble.stopExchange();
  }

  // Called when data is sent using `FlutterForegroundTask.sendDataToTask`.
  @override
  void onReceiveData(Object data) {
    if (kDebugMode) debugPrint('KMTaskHandler onReceiveData: $data');
  }

  // Called when the notification button is pressed.
  @override
  void onNotificationButtonPressed(String id) {
    if (kDebugMode) debugPrint('KMTaskHandler onNotificationButtonPressed: $id');
  }

  // Called when the notification itself is pressed.
  @override
  void onNotificationPressed() {
    if (kDebugMode) debugPrint('KMTaskHandler onNotificationPressed');
  }

  // Called when the notification itself is dismissed.
  @override
  void onNotificationDismissed() {
    if (kDebugMode) debugPrint('KMTaskHandler onNotificationDismissed');
  }

  static Future<void> requestPermissions() async {
    // Android 13+, you need to allow notification permission to display foreground service notification.
    //
    // iOS: If you need notification, ask for permission.
    final NotificationPermission notificationPermission =
    await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // Android 12+, there are restrictions on starting a foreground service.
      //
      // To restart the service on device reboot or unexpected problem, you need to allow below permission.
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        // This function requires `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission.
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      /*
      // Use this utility only if you provide services that require long-term survival,
      // such as exact alarm service, healthcare service, or Bluetooth communication.
      //
      // This utility requires the "android.permission.SCHEDULE_EXACT_ALARM" permission.
      // Using this permission may make app distribution difficult due to Google policy.
      if (!await FlutterForegroundTask.canScheduleExactAlarms) {
        // When you call this function, will be gone to the settings page.
        // So you need to explain to the user why set it.
        await FlutterForegroundTask.openAlarmsAndRemindersSettings();
      }
       */
    }
  }

  static Future<void> initService() async {
    if (kDebugMode) {
      debugPrint('KMTaskHandler initService: '
        'isInitialized ${FlutterForegroundTask.isInitialized}, '
        'isRunningService ${await FlutterForegroundTask.isRunningService}');
    }

    // @visibleForTestingなFlutterForegroundTask.isInitializedを使って判断
    // すでに実行中なら FlutterForegroundTask.initは不要．
    if (FlutterForegroundTask.isInitialized
        && await FlutterForegroundTask.isRunningService) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: 'Foreground Service Notification',
        channelDescription:
        'This notification appears when the foreground service is running.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(), // repeat(5000), // ミリ秒
        // autoRunOnBoot: true,
        // autoRunOnMyPackageReplaced: true,
        // allowWakeLock: true,
        // allowWifiLock: true,
      ),
    );
  }

  static Future<ServiceRequestResult> startService() async {
    if (await FlutterForegroundTask.isRunningService) {
      if (kDebugMode) debugPrint('KMTaskHandler startService すでに実行中');
      // ToDo: パッケージのサンプル通りにrestartService()を呼び出すと，画面がフリーズすることがあるのでやめてみたがあまり変わらない．
      // return ServiceRequestSuccess();
      return FlutterForegroundTask.restartService();
    } else {
      // KeyManagementTaskHandler.initService();
      if (kDebugMode) {
        debugPrint('KMTaskHandler startService start: '
            'isInitialized ${FlutterForegroundTask.isInitialized}, '
            'isRunningService ${await FlutterForegroundTask.isRunningService}');
      }
      // ToDo: isInitialized (@visibleForTesting) が知らないうちにfalseになるので，無理やり初期化している．
      if (! FlutterForegroundTask.isInitialized) initService();

      return FlutterForegroundTask.startService(
        // You can manually specify the foregroundServiceType for the service
        // to be started, as shown in the comment below.
        serviceTypes: [
          ForegroundServiceTypes.connectedDevice,
          ForegroundServiceTypes.location,
        ],
        serviceId: 256,
        notificationTitle: 'Bluetoothと現在位置を使って、近くの人を記録しています',
        notificationText: 'Tap to return to the app',
        notificationIcon: null,
        notificationButtons: [
          const NotificationButton(id: 'btn_stop', text: '記録停止'),
        ],
        notificationInitialRoute: '/',
        callback: startCallback,
      );
    }
  }

  static Future<ServiceRequestResult> stopService() {
    if (kDebugMode) {
      debugPrint('KeyManagementTaskHandler stopService: '
        'isInitialized ${FlutterForegroundTask.isInitialized}');
    }
    return FlutterForegroundTask.stopService();
  }

  static String notificationLocal = '', notificationRemote = '受信なし';

  static Future<void> UpdateNotificationText(
      {Uint8List? localNickname, Uint8List? remoteNickname,
      DateTime? now}) async {
    if (kDebugMode) debugPrint('UpdateNotificationText');
    now ??= DateTime.now();
    final nowStr = DateFormat('MM/dd HH:mm:ss').format(now);
    if (localNickname != null) {
      final str = BleNickname.nickname2string(localNickname, len: 5);
      notificationLocal = '広告: $nowStr, $str\n';
    }
    if (remoteNickname != null) {
      final str = BleNickname.nickname2string(remoteNickname, len: 5);
      notificationRemote = '受信: $nowStr, $str';
    }
    FlutterForegroundTask.updateService(notificationText: notificationLocal + notificationRemote);
  }
}