# 顔見知り証明アプリ

修士論文「リング署名と秘匿共通集合計算を組み合わせた顔見知り証明法」のために作成したアプリ実装です。

平常時に **BLE** ですれ違い時の「仮名（公開鍵）」を収集し、再会時に **gRPC** 通信で **PSI（Private Set Intersection）** と **リング署名**を用いて「顔見知りかどうか」を判定します。

---

## できること

* **近くの人を記録**：BLE で周囲の仮名（公開鍵）を広告・収集し、端末内 DB に保存
* **顔見知りチェック**：QR で接続情報を共有し、gRPC で照合して結果表示

---

## 動作要件

* Flutter（Dart 3.x）
* Android 端末（カメラ / BLE / 位置情報を利用）
* Android Studio + Android SDK/NDK（CMake を含む）
* Protocol Buffers（`protoc`）※ `.proto` を変更する場合のみ

---

## セットアップ

### 1) 依存関係の取得

```bash
flutter pub get
```

### 2) 実行

```bash
flutter run
```

---

## proto のコード生成（.proto を変更した場合）

`.proto` を変更した場合のみ、以下で再生成してください。

```agsl
protoc --proto_path=lib/proto --dart_out=grpc:lib/proto/generated lib/proto/psi.proto
```

---

## OpenSSL のダミー鍵生成

アプリ内で使用する共通したダミー鍵のソースは以下コマンドで生成後、`asset/dummy_keys.txt` に追加します。

初回のみ

```agsl
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

実行（1000鍵生成）

```agsl
.\generate_dummy_keys.ps1 -Count 1000
```

---

## 主要ファイル構成

ネイティブ実装（C）は `src/native/` にあります。

```
.
├─ lib/
│  ├─ main.dart
│  ├─ key_management.dart      # 鍵管理（Secure Storage 等）
│  ├─ ble/                     # BLE 広告・スキャン・ペイロード
│  │  ├─ ble_advertiser.dart
│  │  ├─ ble_scanner.dart
│  │  ├─ ble_protocol.dart
│  │  └─ ble_exchange_controller.dart
│  ├─ grpc/                    # gRPC クライアント/サーバ
│  │  ├─ grpc_client.dart
│  │  ├─ grpc_server.dart
│  │  └─ grpc_common.dart
│  ├─ db/                      # SQLite（sqflite）
│  │  └─ database_helper.dart
│  ├─ pages/                   # 画面（UI）
│  │  ├─ scanner_page.dart
│  │  ├─ exchange_page.dart
│  │  └─ debug_page.dart
│  ├─ ffi/                     # ネイティブ呼び出し（Dart:ffi）
│  │  ├─ native_key_service.dart
│  │  └─ native_key_bindings.dart
│  └─ proto/
│     ├─ grpc.proto            # protobuf 定義
│     └─ generated/
└─ src/
   └─ native/                  # 暗号ライブラリ
      ├─ include/
      ├─ CMakeLists.txt        # ビルド設定
      ├─ key_derivation.c/.h   # 鍵導出
      ├─ psi.c/.h              # PSI
      └─ ring_signature.c/.h   # リング署名
```

---

## 所属

* [広島大学 先進理工系科学研究科 計算機基礎学研究室](https://www.iec.hiroshima-u.ac.jp/)
