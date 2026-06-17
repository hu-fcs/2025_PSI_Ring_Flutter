import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Android フォアグラウンド サービスのために
/// flutter_foreground_task パッケージのexampleをほぼそのまま
/* 動作確認していません．startCallbackと FlutterForegroundTask.initCommunicationPort(); が必要です．
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}
*/

// 2. タスクハンドラーの実装
class BleTaskHandler extends TaskHandler {
  PeripheralManager? _peripheralManager;
  bool _isAdvertising = false;

  // Called when the task is started.
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    log('Background Isolate Started.');
    _peripheralManager = PeripheralManager();
  }

  // Called based on the eventAction set in ForegroundTaskOptions.
  @override
  void onRepeatEvent(DateTime timestamp) async {
    if (_isAdvertising) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'BLE Advertising',
        notificationText: 'アドバタイズを実行中です...',
      );
    }
  }

  // Called when the task is destroyed.
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    log('dummy _stopAdvertising()');
    log('Background Isolate Destroyed.');
  }

  // Called when data is sent using `FlutterForegroundTask.sendDataToTask`.
  @override
  void onReceiveData(Object data) async {
    if (data is String) {
      if (data == 'START_ADV') {
        log('dummy _startAdvertising();');
      } else if (data == 'STOP_ADV') {
        log('dummy _stopAdvertising()');
      }
    }
  }

  // Called when the notification button is pressed.
  @override
  void onNotificationButtonPressed(String id) {
    print('onNotificationButtonPressed: $id');
  }

  // Called when the notification itself is pressed.
  @override
  void onNotificationPressed() {
    print('onNotificationPressed');
  }

  // Called when the notification itself is dismissed.
  @override
  void onNotificationDismissed() {
    print('onNotificationDismissed');
  }
}

// 3. メインUI側からの操作例（参考用）
// メインUIからサービスへ指示を出す場合は以下のように `sendDataToTask` を使用します。
/*
void triggerStartAdvertise() {
  FlutterForegroundTask.sendDataToTask('START_ADV');
}

void triggerStopAdvertise() {
  FlutterForegroundTask.sendDataToTask('STOP_ADV');
}
*/
