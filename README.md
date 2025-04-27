# fluttersample_2025

修士論文「リング署名と秘匿共通集合を組み合わせた顔見知り証明法」のプログラム

- アプリケーション(flutter)
    - 鍵配布
    - 顔見知り確認
- ライブラリ(C++)
    - 鍵ペア生成
    - ハッシュ化
    - 共通集合計算
    - リング署名作成
    - リング署名検証

## 鍵配布

- BLE にて通信する
    - セントラルとペリフェラルを同時に行う
    - 自身のPublicKeyをアドバタイズ
    - 他者のPublicKeyをスキャン
- 実効速度 10kbps くらいで鍵 33 バイト(=264bit)を送る

## 通信フロー 顔見知り確認

```mermaid
sequenceDiagram
    participant サーバ
    participant クライアント

    サーバ->>クライアント: QRコード表示
    クライアント->>サーバ: QRコード読み取り + gRPC接続
    サーバ->>クライアント: 接続OK応答

    Note over サーバ, クライアント: 秘匿共通集合フェーズ

    クライアント->>サーバ: 公開鍵リスト（ハッシュ済み）送信
    サーバ->>クライアント: 公開鍵リスト（ハッシュ済み）送信

    par 双方で共通集合通知
        サーバ->>クライアント: 共通集合のハッシュリスト送信
        クライアント->>サーバ: 共通集合のハッシュリスト送信
    end

    par 双方で共通集合確定
        サーバ->>サーバ: 受信データと照合し共通集合確定
        クライアント->>クライアント: 受信データと照合し共通集合確定
    end

    Note over サーバ, クライアント: リング署名相互認証フェーズ（パラレル進行）

    par 双方同時にチャレンジ送信
        サーバ->>クライアント: チャレンジ乱数送信
        クライアント->>サーバ: チャレンジ乱数送信
    end

    par 双方同時にリング署名作成
        サーバ->>サーバ: チャレンジ受信後にリング署名作成
        クライアント->>クライアント: チャレンジ受信後にリング署名作成
    end

    par 双方同時にリング署名送信
        サーバ->>クライアント: リング署名送信 (32n+32 Byte)
        クライアント->>サーバ: リング署名送信 (32n+32 Byte)
    end

    par 双方同時にリング署名検証
        サーバ->>サーバ: リング署名検証
        クライアント->>クライアント: リング署名検証
    end

    par 双方同時に検証結果送信
        サーバ->>クライアント: 検証結果送信 (OK/NG)
        クライアント->>サーバ: 検証結果送信 (OK/NG)
    end

    Note over サーバ, クライアント: 検証結果送信完了後、即ストリーム終了
```

## 暗号ライブラリ関数一覧

| 関数名 | 役割 | 引数 | 戻り値 |
|:------|:-----|:----|:------|
| `GenerateKeyPair` | 秘密鍵と公開鍵を生成する | なし | `(std::string privateKey, std::string publicKey)` |
| `HashPublicKeys` | 公開鍵リストをハッシュ化する | `const std::vector<std::string>& publicKeys` | `std::vector<std::string>` ハッシュ済み公開鍵リスト |
| `ComputeCommonSet` | 自分と相手のハッシュリストから共通集合を求める | `const std::vector<std::string>& myHashes`,<br>`const std::vector<std::string>& peerHashes` | `std::vector<std::string>` 共通ハッシュリスト |
| `CreateRingSignature` | リング署名を作成する | `const std::vector<std::string>& publicKeys`,<br>`const std::string& privateKey`,<br>`const std::string& message` | `std::vector<uint8_t>` リング署名データ |
| `VerifyRingSignature` | リング署名を検証する | `const std::vector<std::string>& publicKeys`,<br>`const std::string& message`,<br>`const std::vector<uint8_t>& signature` | `bool` 検証成功なら`true` |
