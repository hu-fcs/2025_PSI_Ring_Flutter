# 近くの友達を発見し顔見知りを証明するアプリ

修士論文「リング署名と秘匿共通集合計算を組み合わせた顔見知り証明法」と卒業論文「BLEを使った信頼関係に基づく近接認識方式の提案と実装」のために作成したアプリ実装です。

顔見知り証明：平常時に **BLE** ですれ違い時の「仮名（公開鍵）」を収集し、再会時に **gRPC** 通信で **PSI（Private Set Intersection）** と **リング署名**を用いて「顔見知りかどうか」を判定します。

近接認識：事前に友人同士で **gRPC** を用いて「将来一定期間分のニックネーム（10分ごとに変化する公開鍵）リスト」を共有しておくことで、**BLE** ですれ違った瞬間にリストと照合するだけで「近くに友人がいるか」を判定します。ニックネームリストの漏洩によるなりすましを防ぐため、候補検出後に **ECDSA** 署名によるチャレンジレスポンス認証を行い、本人確認をします。

## 動作要件

* Flutter（Dart 3.x）
* Android 端末（カメラ / BLE / 位置情報を利用）
* Android Studio + Android SDK/NDK（CMake を含む）
* Protocol Buffers（`protoc`）※ `.proto` を変更する場合のみ

## セットアップ

### 1) 依存関係の取得

```bash
flutter pub get
```

### 2) 実行

```bash
flutter run
```

## proto のコード生成

`.proto` を変更した場合のみ、以下で再生成してください。

```agsl
protoc --proto_path=lib/proto --dart_out=grpc:lib/proto/generated lib/proto/grpc.proto
```

## gPRC自己証明書
アルゴリズム ECDSA（P-256）

注意：Gitリポジトリに server.key と server.crt を含めないこと。
```
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 365 \
-keyout assets/grpc/server.key \
-out assets/grpc/server.crt \
-subj "/CN=application.local"
```

## OpenSSL のダミー鍵生成

アプリ内で使用する共通したダミー鍵のソースは以下コマンドで生成後、`asset/dummy_keys.txt` に追加します。

初回のみ

```agsl
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

実行（1000鍵生成）

```powershell
generate_dummy_keys.ps1 -Count 1000
```

## 主要ファイル構成

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

## 所属

* [広島大学 先進理工系科学研究科 計算機基礎学研究室](https://www.iec.hiroshima-u.ac.jp/)
