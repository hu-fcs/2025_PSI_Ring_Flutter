nicknamelist branch 51c5c7f
を
master branch d8e32a6
に
merge するプラン

This branch is 2 commits ahead of and 73 commits behind master.

- 2 commits ahead:
  `16 changed files with 1,645 additions and 13 deletions.`
  [patch](nickanmelist-merge-plan.patch)
- 73 commits behind:
  `70 changed files  with 1,206,764 additions and 2,825 deletions.`

# 今後したいこと ToDo
- 両方がCentralになって認証を開始すると二重になり無駄．
- 自分の名前と識別子を shared_preference に保存する．
- 認証後に，その端末からの広告を受信するたびに，近くの友達の表示を維持する．
- 同一友達の連続通知を抑制を反映できていない `lib/ble/ble_scanner.dart`（nicknamelist branch 51c5c7f）

# 途中経過
- 画面への通知はCentral側の場合のみ．
- `exchange_page.dart: _grpcClient.sendNicknameSchedule()` grpc部分をprotobufを使って再実装した．双方向に将来ニックネームを交換する．
- `lib/ble/key_advertise_repository.dart`は使っていないようなので削除した．
- 画面のTextのフォントサイズなどをTextThemeを使うようにした．
- friend_nicknames テーブルに一致する友達ラベルがないか検索
  `final labels = await FriendsDao.instance.findFriendLabelsByPubkey(merged);`
- 友達が見つかったときに画面に表示するためのコールバックを設定
  `exchange_page.dart: _ble.onFriendDetected = _onFriendDitected;` 
- 相互認証のフローを実装．一部未完成
- 相互認証でPeripheral側がCentral側のニックネームを覚えていない．

# マージ（結合）プラン

main branch を下敷きにして，2 commits ahead の変更内容を反映する．

- master側でのファイル名変更やファイル移動を nickname branch に反映

```
git mv lib/key_management_service.dart lib/key_management.dart
git mv lib/native_key_bindings.dart lib/ffi/native_key_bindings.dart
git mv lib/native_key_service.dart lib/ffi/native_key_service.dart
git mv lib/grpc/psi_server.dart lib/grpc/grpc_server.dart
git mv lib/grpc/psi_client.dart lib/grpc/grpc_cliennt.dart
git mv lib/proto/psi.proto lib/proto/grpc.proto
git mv lib/proto/generated/psi.pb.dart lib/proto/generated/grpc.pb.dart
git mv lib/proto/generated/psi.pbgrpc.dart lib/proto/generated/grpc.pbgrpc.dart
git mv lib/proto/generated/psi.pbjson.dart lib/proto/generated/grpc.pbjson.dart
git mv lib/proto/generated/psi.pbenum.dart lib/proto/generated/grpc.pbenum.dart
```

- main branchのファイルで上書き
  `git restore --source master .
  `

- friends, friend_nicknamesの二つの表をデータベースに追加．
  - `lib/db/database_helper.dart` 変更 済み
  - `lib/db/friends_dao.dart` 新規
- 将来ニックネームの生成
  - `lib/key_management_service.dart` 変更 済み
- 将来ニックネームの送受信（JSON．masterはprotbufに変更されている）
  - `lib/grpc/psi_client.dart` 変更
  - `lib/grpc/psi_server.dart` 変更
- チャレンジレスポンス認証
  - `lib/native_key_bindings.dart` 変更 済み
  - `lib/native_key_service.dart` 変更 済み
  - `src/native/ring_signature.c` 変更 済み ecdsa.c
  - `src/native/ring_signature.h` 変更 済み ecdsa.h
- デバッグページの友達タブ追加
  - `lib/pages/debug_page.dart` 変更 済み
- 初期ページ
  - `lib/pages/exchange_page.dart` 変更 済み
- BLE関連（masterは広告からconnect/read/writeに変更されている）
  - `lib/ble/ble_advertiser.dart` 変更 削除
  - `lib/ble/ble_constants.dart` 変更 削除
  - `lib/ble/ble_exchange_controller.dart` 変更 削除
  - `lib/ble/ble_scanner.dart` 変更 削除
  - `lib/ble/ecd_keys_dao.dart` 新規 削除
  - `lib/ble/key_advertise_repository.dart` 新規 削除
- README.md 1行追加

## READMEの図がなくなるのが心残り
```mermaid
```

## master branchの変更
- lib/proto/psi.proto から lib/proto/grpc.proto に大きな変更．
  - master's Commit 15c9007 byte列でgRPC通信を行うよう修正．JSONからprotobufに．
  - grpc/* に影響．
- lib/ble/* のBLEパッケージ変更．
  - チャレンジレスポンス関連の移行:
	lib/ble/ecd_keys_dao.dart と
	lib/ble/key_advertise_repository.dart
- UI変更
  - lib/pages/exchange_page.dart
    - 周囲の知り合いを表示する部分
	- 将来ニックネームを交換する部分
  - lib/pages/debug_page.dart
  	- 将来ニックネーム
- ファイル削除．debug_page.dartでimportしているが，
  master branchではimportしていないので削除してよいだろう．
  -  lib/boringssl_service.dart
- README.md
  - marmaidで書いた図が削除されているのを復活させたい
- assets/dummy_keys.txt が master branch に作られているのは使えそう．

## ファイル移動など
## ファイル追加・削除
```
削除 +0 −187  lib/ble/ble_advertiser.dart
削除 +0 −45  lib/ble/ble_constants.dart
削除 +0 −23  lib/ble/ble_exchange_controller.dart
削除 +0 −226  lib/ble/ble_scanner.dart
追加 +264 −0  lib/ble/central.dart
削除 +0 −35  lib/ble/ecd_keys_dao.dart
削除 +0 −25  lib/ble/key_advertise_repository.dart
+336 −0  lib/ble/mutual_authentication.dart
+240 −0  lib/ble/nickname.dart
+205 −0  lib/ble/peripheral.dart
+88 −0  lib/ble/task_handler.dart
+0 −74  lib/boringssl_service.dart
+203 −43  lib/db/database_helper.dart
+342 −0  lib/grpc/grpc_client.dart
+92 −0  lib/grpc/grpc_common.dart
+415 −0  lib/grpc/grpc_server.dart
+0 −102  lib/grpc/psi_client.dart
+0 −102  lib/grpc/psi_server.dart
+16 −12  lib/main.dart
+587 −471  lib/pages/debug_page.dart
+677 −183  lib/pages/exchange_page.dart
+250 −187  lib/pages/scanner_page.dart
+440 −0  lib/proto/generated/grpc.pb.dart
+1 −1  lib/proto/generated/{psi.pbenum.dart → grpc.pbenum.dart}
+160 −0  lib/proto/generated/grpc.pbgrpc.dart
+138 −0  lib/proto/generated/grpc.pbjson.dart
+0 −128  lib/proto/generated/psi.pb.dart
+0 −70  lib/proto/generated/psi.pbgrpc.dart
+0 −40  lib/proto/generated/psi.pbjson.dart
+53 −0  lib/proto/grpc.proto
+0 −14  lib/proto/psi.proto

## 
Zuaki21 committed on Dec 3, 2025


## master's Commit d0e47e0
Zuaki21 committed on Dec 5, 2025
ファイル整理
psi_*.dart が grpc_*.dart に

# key_management_service.dart
## Commit f89e8ed
Zuaki21 committed on Jan 31
READMEの変更
key_management_service.dart が key_management.dart に

# boringssl_service.dart がなくなっている
## Commit fe3adb3
Zuaki21 authored on Jan 31
Merge pull request #17 from hu-fcs/sugiura-for_test_feature
削除された

# ffi
## Commit d0e47e0
Zuaki21 committed on Dec 5, 2025
ファイル整理
lib/native_key_bindings.dart‎ が lib/ffi/native_key_bindings.dart‎ に
lib/native_key_service.dart が lib/ffi/native_key_service.dart‎ に

# ble
## Commit d8e32a6
kitasuka 18 hours ago
ニックネームの広告方法の変更
削除
ble/ble_advertiser.dart
ble/ble_constants.dart
ble/ble_exchange_controller.dart
ble/ble_scanner.dart
ble/ecd_keys_dao.dart
ble/key_advertise_repository.dart
追加
ble/central.dart
ble/mutual_authentication.dart
ble/nickname.dart
ble/peripheral.dart
ble/task_handler.dart
