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
  - 自身の PublicKey をアドバタイズ
  - 他者の PublicKey をスキャン
- 実効速度 10kbps くらいで鍵 33 バイト(=264bit)を送る

## 通信フロー 顔見知り確認

- クライアント: 公開鍵リスト X = {x1, x2, ..., xn} を保持
- サーバ: 公開鍵リスト Y = {y1, y2, ..., ym} を保持

```mermaid
sequenceDiagram
    participant サーバ
    participant クライアント

    サーバ->>クライアント: QRコード表示
    クライアント->>サーバ: QRコード読み取り + gRPC接続
    サーバ->>クライアント: 接続OK応答

    Note over サーバ, クライアント: 秘匿共通集合フェーズ

    par 同時に処理
        par クライアント→サーバ
        クライアント->>クライアント: ランダム秘密値 s を生成
        クライアント->>クライアント: H(X)^s を計算
        クライアント->>サーバ: H(X)^s 送信
        end
        par サーバ→クライアント
        サーバ->>サーバ: ランダム秘密値 c を生成
        サーバ->>サーバ: H(Y)^c を計算
        サーバ->>クライアント: H(Y)^c 送信
        end
    end

    par 同時に処理
        par クライアント側が共通集合を得る

        クライアント->>クライアント: H(Y)^cs を計算
        クライアント->>サーバ: H(Y)^cs 送信
        サーバ->>サーバ: H(Y)^s = (H(Y)^cs)^(-c) を計算
        サーバ->>サーバ: H(X)^s と H(Y)^s から H(X∩Y)^s を得る
        サーバ->>クライアント: H(X∩Y)^s 送信
        クライアント->>クライアント: H(X∩Y)=(H(X∩Y)^s)^(-s)を計算
        end
        par サーバ側が共通集合を得る
        サーバ->>サーバ: H(X)^cs を計算
        サーバ->>クライアント: H(X)^cs 送信
        クライアント->>クライアント: H(X)^c = (H(X)^cs)^(-s) を計算
        クライアント->>クライアント: H(Y)^cとH(X)^cからH(X∩Y)^cを得る
        クライアント->>サーバ: H(X∩Y)^c 送信
        サーバ->>サーバ: H(X∩Y)=(H(X∩Y)^c)^(-c)を計算
        end
    end

    Note over サーバ, クライアント: リング署名相互認証フェーズ（パラレル進行）
    par 同時に処理
        par 双方同時にチャレンジ送信
            サーバ->>クライアント: チャレンジ乱数送信
            クライアント->>クライアント: チャレンジ受信後にリング署名作成
            クライアント->>サーバ: リング署名送信 (32n+32 Byte)
            サーバ->>サーバ: リング署名検証
            サーバ->>クライアント: 検証結果送信 (OK/NG)
        end

        par 双方同時にリング署名作成
            クライアント->>サーバ: チャレンジ乱数送信
            サーバ->>サーバ: チャレンジ受信後にリング署名作成
            サーバ->>クライアント: リング署名送信 (32n+32 Byte)
            クライアント->>クライアント: リング署名検証
            クライアント->>サーバ: 検証結果送信 (OK/NG)
        end
    end
    Note over サーバ, クライアント: 検証結果を送り合った後、ストリーム終了
```

## 暗号ライブラリ関数一覧

| 関数名                | 役割                                           | 引数                                                                                                                      | 戻り値                                              |
| :-------------------- | :--------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------ | :-------------------------------------------------- |
| `GenerateKeyPair`     | 秘密鍵と公開鍵を生成する                       | なし                                                                                                                      | `(std::string privateKey, std::string publicKey)`   |
| `HashPublicKeys`      | 公開鍵リストをハッシュ化する                   | `const std::vector<std::string>& publicKeys`                                                                              | `std::vector<std::string>` ハッシュ済み公開鍵リスト |
| `ComputeCommonSet`    | 自分と相手のハッシュリストから共通集合を求める | `const std::vector<std::string>& myHashes`,<br>`const std::vector<std::string>& peerHashes`                               | `std::vector<std::string>` 共通ハッシュリスト       |
| `CreateRingSignature` | リング署名を作成する                           | `const std::vector<std::string>& publicKeys`,<br>`const std::string& privateKey`,<br>`const std::string& message`         | `std::vector<uint8_t>` リング署名データ             |
| `VerifyRingSignature` | リング署名を検証する                           | `const std::vector<std::string>& publicKeys`,<br>`const std::string& message`,<br>`const std::vector<uint8_t>& signature` | `bool` 検証成功なら`true`                           |
