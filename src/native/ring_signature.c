#include "ring_signature.h"
#include <stdlib.h>
#include <string.h>

// --- Androidログ出力用のヘッダーを追加 ---
#include <android/log.h>

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/crypto.h>

// --- ログ出力用のマクロを定義 ---
#define LOG_TAG "RingSignatureJNI" // Logcatでフィルタリングするためのタグ
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)


// --- 内部ヘルパー関数 (変更なし) ---

static EVP_PKEY* pkey_from_pub_bytes(const uint8_t* pub_key_bytes, BN_CTX* ctx) {
    EVP_PKEY* pkey = NULL;
    EC_KEY* ec_key = NULL;
    const EC_GROUP* group = NULL;
    EC_POINT* pub_point = NULL;
    ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec_key) goto cleanup;
    group = EC_KEY_get0_group(ec_key);
    pub_point = EC_POINT_new(group);
    if (!pub_point) goto cleanup;
    if (!EC_POINT_oct2point(group, pub_point, pub_key_bytes, PUB_KEY_LEN, ctx)) goto cleanup;
    if (!EC_KEY_set_public_key(ec_key, pub_point)) goto cleanup;
    pkey = EVP_PKEY_new();
    if (!pkey) goto cleanup;
    if (!EVP_PKEY_set1_EC_KEY(pkey, ec_key)) {
        EVP_PKEY_free(pkey);
        pkey = NULL;
    }
    cleanup:
    if (ec_key) EC_KEY_free(ec_key);
    if (pub_point) EC_POINT_free(pub_point);
    return pkey;
}

static void hash_for_ring(const char *msg, size_t msg_len, const EC_POINT *point, const EC_GROUP *group, BIGNUM *result, BN_CTX *ctx) {
    size_t len = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, NULL, 0, ctx);
    unsigned char *buf = malloc(len);
    if (!buf) return;
    EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, buf, len, ctx);
    uint8_t digest[HASH_LEN];
    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(mdctx, msg, msg_len);
    EVP_DigestUpdate(mdctx, buf, len);
    EVP_DigestFinal_ex(mdctx, digest, NULL);
    BN_bin2bn(digest, HASH_LEN, result);
    free(buf);
    EVP_MD_CTX_free(mdctx);
}


// --- 公開APIの実装 ---

EXPORT int create_ring_signature(const char* msg, size_t msg_len, const uint8_t* signer_priv_key_32b, const uint8_t* ring_pub_keys, int ring_size, uint8_t* out_signature) {
    LOGI("create_ring_signature: 開始 (リングサイズ: %d)", ring_size);
    if (ring_size < 2) {
        LOGE("エラー: リングサイズが2未満です。");
        return 0;
    }

    int ret = 0;
    int signer_idx = -1;

    BN_CTX* ctx = NULL;
    BIGNUM* priv_bn = NULL;
    EVP_PKEY** ring_pkeys = NULL;
    EC_POINT* signer_pub_point = NULL;
    const EC_GROUP* group = NULL;
    BIGNUM *alpha = NULL, *C = NULL, *tmp = NULL, *c0_final = NULL;
    BIGNUM** s_values = NULL;
    EC_POINT *L = NULL;

    ctx = BN_CTX_new();
    if (!ctx) { LOGE("BN_CTX_new 失敗"); goto cleanup; }
    BN_CTX_start(ctx);
    LOGI("ステップ1: コンテキスト初期化完了");

    priv_bn = BN_bin2bn(signer_priv_key_32b, PRIV_KEY_LEN, NULL);
    ring_pkeys = calloc(ring_size, sizeof(EVP_PKEY*));
    s_values = calloc(ring_size, sizeof(BIGNUM*));
    if (!priv_bn || !ring_pkeys || !s_values) { LOGE("メモリ確保失敗 (priv_bn/ring_pkeys/s_values)"); goto cleanup; }
    LOGI("ステップ2: 主要なメモリ確保完了");

    for (int i = 0; i < ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN, ctx);
        if (!ring_pkeys[i]) { LOGE("pkey_from_pub_bytes 失敗 (index: %d)", i); goto cleanup; }
    }
    group = EC_KEY_get0_group(EVP_PKEY_get0_EC_KEY(ring_pkeys[0]));
    LOGI("ステップ3: リング公開鍵のEVP_PKEYへの変換完了");

    signer_pub_point = EC_POINT_new(group);
    if (!signer_pub_point) { LOGE("EC_POINT_new 失敗 (signer_pub_point)"); goto cleanup; }
    if (!EC_POINT_mul(group, signer_pub_point, priv_bn, NULL, NULL, ctx)) { LOGE("EC_POINT_mul 失敗 (署名者公開鍵の計算)"); goto cleanup; }

    uint8_t signer_pub_key_buf[PUB_KEY_LEN];
    if (EC_POINT_point2oct(group, signer_pub_point, POINT_CONVERSION_UNCOMPRESSED, signer_pub_key_buf, PUB_KEY_LEN, ctx) == 0) { LOGE("EC_POINT_point2oct 失敗"); goto cleanup; }

    for (int i = 0; i < ring_size; ++i) {
        if (memcmp(signer_pub_key_buf, ring_pub_keys + i * PUB_KEY_LEN, PUB_KEY_LEN) == 0) {
            signer_idx = i;
            break;
        }
    }
    if (signer_idx == -1) { LOGE("エラー: 署名者がリング内に見つかりません。"); goto cleanup; }
    LOGI("ステップ4: 署名者のインデックス特定完了 (index: %d)", signer_idx);

    const BIGNUM *order = EC_GROUP_get0_order(group);
    alpha = BN_CTX_get(ctx);
    C = BN_CTX_get(ctx);
    L = EC_POINT_new(group);
    if (!alpha || !C || !L) { LOGE("メモリ確保失敗 (alpha/C/L)"); goto cleanup; }

    BN_rand_range(alpha, order);
    EC_POINT_mul(group, L, alpha, NULL, NULL, ctx);
    hash_for_ring(msg, msg_len, L, group, C, ctx);
    LOGI("ステップ5: 初期ハッシュ計算完了");

    for (int i = 1; i < ring_size; ++i) {
        int cur = (signer_idx + i) % ring_size;
        s_values[cur] = BN_new();
        if (!s_values[cur]) { LOGE("BN_new 失敗 (s_values[%d])", cur); goto cleanup; }
        BN_rand_range(s_values[cur], order);
        const EC_POINT *P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[cur]));
        EC_POINT_mul(group, L, s_values[cur], P, C, ctx);
        hash_for_ring(msg, msg_len, L, group, C, ctx);
    }
    LOGI("ステップ6: ハッシュチェーン計算完了");

    c0_final = BN_dup(C);
    if (!c0_final) { LOGE("BN_dup 失敗 (c0_final)"); goto cleanup; }

    s_values[signer_idx] = BN_new();
    tmp = BN_CTX_get(ctx);
    if (!s_values[signer_idx] || !tmp) { LOGE("メモリ確保失敗 (s_values[signer_idx]/tmp)"); goto cleanup; }

    BN_mod_mul(tmp, C, priv_bn, order, ctx);
    BN_mod_sub(s_values[signer_idx], alpha, tmp, order, ctx);
    LOGI("ステップ7: 署名者部分の計算完了");

    BN_bn2binpad(c0_final, out_signature, HASH_LEN);
    for(int i = 0; i < ring_size; ++i) {
        if (s_values[i]) {
            BN_bn2binpad(s_values[i], out_signature + (i + 1) * HASH_LEN, HASH_LEN);
        }
    }
    LOGI("ステップ8: 署名のシリアライズ完了");

    ret = 1;
    LOGI("create_ring_signature: 正常終了");

    cleanup:
    if (ret == 0) {
        LOGE("create_ring_signature: エラーにより処理中断。クリーンアップ実行。");
    }
    if (ctx) { BN_CTX_end(ctx); BN_CTX_free(ctx); }
    if (priv_bn) BN_free(priv_bn);
    if (signer_pub_point) EC_POINT_free(signer_pub_point);
    if (ring_pkeys) {
        for (int i = 0; i < ring_size; ++i) if (ring_pkeys[i]) EVP_PKEY_free(ring_pkeys[i]);
        free(ring_pkeys);
    }
    if (c0_final) BN_free(c0_final);
    if (s_values) {
        for (int i = 0; i < ring_size; ++i) if (s_values[i]) BN_free(s_values[i]);
        free(s_values);
    }
    if (L) EC_POINT_free(L);

    return ret;
}

// verify関数は今回変更なし
EXPORT int verify_ring_signature(const char* msg, size_t msg_len, const uint8_t* signature, const uint8_t* ring_pub_keys, int ring_size) {
    if (ring_size < 2) return 0;
    int ret = 0;
    BN_CTX* ctx = NULL;
    EVP_PKEY** ring_pkeys = NULL;
    BIGNUM** s_values = NULL;
    BIGNUM* c0 = NULL;
    BIGNUM* C = NULL;
    EC_POINT* L = NULL;
    const EC_GROUP* group = NULL;
    ctx = BN_CTX_new();
    if (!ctx) goto cleanup;
    ring_pkeys = calloc(ring_size, sizeof(EVP_PKEY*));
    s_values = calloc(ring_size, sizeof(BIGNUM*));
    if (!ring_pkeys || !s_values) goto cleanup;
    c0 = BN_bin2bn(signature, HASH_LEN, NULL);
    C = BN_dup(c0);
    if (!c0 || !C) goto cleanup;
    for (int i = 0; i < ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN, ctx);
        s_values[i] = BN_bin2bn(signature + (i + 1) * HASH_LEN, HASH_LEN, NULL);
        if (!ring_pkeys[i] || !s_values[i]) goto cleanup;
    }
    group = EC_KEY_get0_group(EVP_PKEY_get0_EC_KEY(ring_pkeys[0]));
    L = EC_POINT_new(group);
    if (!L) goto cleanup;
    for (int i = 0; i < ring_size; ++i) {
        const EC_POINT *P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[i]));
        if (!EC_POINT_mul(group, L, s_values[i], P, C, ctx)) goto cleanup;
        hash_for_ring(msg, msg_len, L, group, C, ctx);
    }
    if (BN_cmp(c0, C) == 0) {
        ret = 1;
    }
    cleanup:
    if (ctx) BN_CTX_free(ctx);
    if (c0) BN_free(c0);
    if (C) BN_free(C);
    if (ring_pkeys) {
        for(int i = 0; i < ring_size; ++i) if(ring_pkeys[i]) EVP_PKEY_free(ring_pkeys[i]);
        free(ring_pkeys);
    }
    if (s_values) {
        for(int i = 0; i < ring_size; ++i) if(s_values[i]) BN_free(s_values[i]);
        free(s_values);
    }
    if (L) EC_POINT_free(L);
    return ret;
}
