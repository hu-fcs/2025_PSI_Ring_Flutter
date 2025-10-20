#include "key_derivation.h"
#include <string.h>

// OpenSSLライブラリのヘッダー
#include <openssl/rand.h>
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/ec.h>
#include <openssl/bn.h>

// 秘密鍵の元となるデータの長さ（SHA256のハッシュ長）
#define HASH_LEN 32

/**
 * @brief 32バイトの暗号学的に安全なマスターキーを生成する。
 * OpenSSLの乱数生成関数 RAND_bytes を使用する。
 */
int generate_master_key(uint8_t* out_master_key_32b) {
    // 成功すると1が返る
    return RAND_bytes(out_master_key_32b, HASH_LEN);
}

/**
 * @brief マスターキーとタイムスタンプから鍵ペアを導出する。
 * タイムスロットの間隔を引数で指定できる。
 *
 * 出力する公開鍵は圧縮形式(33バイト)に変更。
 */
int derive_keypair_from_timestamp(
        const uint8_t* master_key,
        uint64_t timestamp_ms,
        uint64_t slot_ms, // タイムスロットの間隔（ミリ秒）
        uint8_t* out_priv_key_32b,
        uint8_t* out_pub_key_33b
) {
    // リソースへのポインタ。安全な解放処理のためNULLで初期化。
    EVP_PKEY_CTX* pctx = NULL;
    EC_KEY* ec_key = NULL;
    BIGNUM* priv_bn = NULL;
    const EC_GROUP* group = NULL;
    EC_POINT* pub_point = NULL;
    BN_CTX* bn_ctx = NULL;
    int ret = 0; // 戻り値。成功時に1になる。

    // 0除算を避けるためのチェック
    if (slot_ms == 0) {
        return 0;
    }
    // 引数で受け取ったslot_msでタイムスタンプを丸め、タイムスロットを計算
    uint64_t slot_time = (timestamp_ms / slot_ms) * slot_ms;

    // HKDFのsaltとしてタイムスロットを使用する
    uint8_t salt[8];
    for (int i = 0; i < 8; i++) {
        // 64ビット整数をBig Endianでバイト配列に変換
        salt[7 - i] = (uint8_t)((slot_time >> (8 * i)) & 0xFF);
    }

    // 鍵の用途を識別するための固定文字列 (info)
    const char* info_str = "ecdsakey";
    uint8_t derived_priv_bytes[HASH_LEN];

    // HKDFで秘密鍵の元となる32バイトのデータを導出
    pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
    if (!pctx) goto cleanup; // エラーが発生した場合はcleanupセクションへジャンプ
    if (EVP_PKEY_derive_init(pctx) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set_hkdf_md(pctx, EVP_sha256()) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set1_hkdf_salt(pctx, salt, sizeof(salt)) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set1_hkdf_key(pctx, master_key, HASH_LEN) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_add1_hkdf_info(pctx, (const void*)info_str, strlen(info_str)) <= 0) goto cleanup;

    size_t derived_len = HASH_LEN;
    if (EVP_PKEY_derive(pctx, derived_priv_bytes, &derived_len) <= 0) goto cleanup;
    if (derived_len != HASH_LEN) goto cleanup;

    // --- ここからEC鍵ペアの生成 ---
    // secp256r1 (NID_X9_62_prime256v1) のECキーオブジェクトを生成
    ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec_key) goto cleanup;

    // 導出したバイト列をBIGNUM形式の秘密鍵に変換
    priv_bn = BN_bin2bn(derived_priv_bytes, HASH_LEN, NULL);
    if (!priv_bn) goto cleanup;

    group = EC_KEY_get0_group(ec_key);
    pub_point = EC_POINT_new(group);
    bn_ctx = BN_CTX_new();
    if (!pub_point || !bn_ctx) goto cleanup;

    // 秘密鍵から公開鍵 (EC_POINT) を計算 (G * priv_bn)
    if (!EC_POINT_mul(group, pub_point, priv_bn, NULL, NULL, bn_ctx)) goto cleanup;

    // ECキーオブジェクトに秘密鍵と公開鍵を設定
    if (!EC_KEY_set_private_key(ec_key, priv_bn)) goto cleanup;
    if (!EC_KEY_set_public_key(ec_key, pub_point)) goto cleanup;

    // --- 結果を出力バッファにコピー ---
    // 秘密鍵を32バイトの固定長でコピー
    if (BN_bn2binpad(priv_bn, out_priv_key_32b, 32) != 32) goto cleanup;

    // 公開鍵を圧縮形式(33バイト)でコピー
    // まず必要サイズを問い合わせる（OpenSSLは必要長を返す）。
    size_t need = EC_POINT_point2oct(group, pub_point, POINT_CONVERSION_COMPRESSED, NULL, 0, bn_ctx);
    if (need != 33) goto cleanup; // secp256r1 圧縮は常に 33 バイト（0x02/0x03 + X座標32B）

    if (EC_POINT_point2oct(group, pub_point, POINT_CONVERSION_COMPRESSED, out_pub_key_33b, 33, bn_ctx) != 33)
        goto cleanup;

    ret = 1; // 全て成功

    cleanup:
    // エラー発生時または正常終了時に確保したメモリを解放
    if (pctx) EVP_PKEY_CTX_free(pctx);
    if (ec_key) EC_KEY_free(ec_key);
    if (priv_bn) BN_free(priv_bn);
    if (pub_point) EC_POINT_free(pub_point);
    if (bn_ctx) BN_CTX_free(bn_ctx);

    return ret;
}
