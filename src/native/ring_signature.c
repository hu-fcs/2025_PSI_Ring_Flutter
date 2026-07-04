#include "ring_signature.h"
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/crypto.h>

#define LOG_TAG "RingSignatureJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* ---- 内部関数 ---- */

/* 圧縮公開鍵(33B)を EVP_PKEY に変換する */
static EVP_PKEY* pkey_from_pub_bytes(const uint8_t* pub_key_bytes, BN_CTX* ctx) {
    EVP_PKEY* pkey = NULL;
    EC_KEY* ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec_key) return NULL;

    const EC_GROUP* group = EC_KEY_get0_group(ec_key);
    EC_POINT* pub_point = EC_POINT_new(group);
    if (!pub_point) {
        EC_KEY_free(ec_key);
        return NULL;
    }

    if (EC_POINT_oct2point(group, pub_point, pub_key_bytes, PUB_KEY_LEN, ctx) &&
        EC_KEY_set_public_key(ec_key, pub_point)) {
        pkey = EVP_PKEY_new();
        if (pkey) {
            EVP_PKEY_set1_EC_KEY(pkey, ec_key);
        }
    }

    EC_POINT_free(pub_point);
    EC_KEY_free(ec_key);
    return pkey;
}

/*
 * c_i の計算: H(m || L) を整数に写像する。
 * L は非圧縮形式でエンコードしてハッシュに入力する。
 */
static void hash_for_ring(
        const char *msg,
        size_t msg_len,
        const EC_POINT *point,
        const EC_GROUP *group,
        BIGNUM *result,
        BN_CTX *ctx
) {
    size_t len = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, NULL, 0, ctx);
    unsigned char *buf = (unsigned char*)malloc(len);
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

/* ---- 公開 API ---- */

EXPORT int create_ring_signature(
        const char* msg,
        size_t msg_len,
        const uint8_t* signer_priv_key_32b,
        const uint8_t* ring_pub_keys,
        int ring_size,
        uint8_t* out_signature
) {
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
    const EC_GROUP* group = NULL;
    const BIGNUM *order = NULL;
    BIGNUM** c_values = NULL;
    BIGNUM** s_values = NULL;
    EC_POINT* L = NULL;

    ctx = BN_CTX_new();
    if (!ctx) { LOGE("BN_CTX_new 失敗"); goto cleanup; }
    BN_CTX_start(ctx);

    priv_bn = BN_bin2bn(signer_priv_key_32b, PRIV_KEY_LEN, NULL);
    ring_pkeys = (EVP_PKEY**)calloc(ring_size, sizeof(EVP_PKEY*));
    c_values = (BIGNUM**)calloc(ring_size, sizeof(BIGNUM*));
    s_values = (BIGNUM**)calloc(ring_size, sizeof(BIGNUM*));
    if (!priv_bn || !ring_pkeys || !c_values || !s_values) { LOGE("メモリ確保失敗 1"); goto cleanup; }

    for (int i = 0; i < ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN, ctx);
        if (!ring_pkeys[i]) { LOGE("pkey_from_pub_bytes 失敗 (index: %d)", i); goto cleanup; }
    }

    group = EC_KEY_get0_group(EVP_PKEY_get0_EC_KEY(ring_pkeys[0]));
    order = EC_GROUP_get0_order(group);

    L = EC_POINT_new(group);
    if (!L) { LOGE("EC_POINT_new 失敗"); goto cleanup; }

    /*
     * 署名者インデックスの特定:
     * 秘密鍵から対応する圧縮公開鍵(33B)を計算し，リング内の公開鍵列と照合する。
     */
    {
        uint8_t temp_pub_buf[PUB_KEY_LEN];
        EC_POINT* temp_pub_point = EC_POINT_new(group);
        if (!temp_pub_point) { LOGE("EC_POINT_new 失敗 (temp)"); goto cleanup; }

        EC_POINT_mul(group, temp_pub_point, priv_bn, NULL, NULL, ctx);
        size_t wrote = EC_POINT_point2oct(
                group,
                temp_pub_point,
                POINT_CONVERSION_COMPRESSED,
                temp_pub_buf,
                PUB_KEY_LEN,
                ctx
        );
        EC_POINT_free(temp_pub_point);

        if (wrote != PUB_KEY_LEN) { LOGE("point2oct 圧縮出力長が不正: %zu", wrote); goto cleanup; }

        for (int i = 0; i < ring_size; ++i) {
            if (memcmp(temp_pub_buf, ring_pub_keys + i * PUB_KEY_LEN, PUB_KEY_LEN) == 0) {
                signer_idx = i;
                break;
            }
        }
    }

    if (signer_idx == -1) { LOGE("エラー: 署名者がリング内に見つかりません。"); goto cleanup; }
    LOGI("署名者インデックス特定完了 (index: %d)", signer_idx);

    /* 署名生成（AOS 形式） */

    /* 1. 署名者以外の s_i を一様乱数で生成する */
    for (int i = 0; i < ring_size; ++i) {
        if (i == signer_idx) continue;
        s_values[i] = BN_new();
        if (!s_values[i]) { LOGE("BN_new 失敗 (s_values)"); goto cleanup; }
        BN_rand_range(s_values[i], order);
    }

    /* 2. α を選び，c_{k+1} = H(m, G*α) を計算する */
    BIGNUM* alpha = BN_CTX_get(ctx);
    if (!alpha) { LOGE("BN_CTX_get 失敗 (alpha)"); goto cleanup; }
    BN_rand_range(alpha, order);

    EC_POINT_mul(group, L, alpha, NULL, NULL, ctx); // L = G * alpha

    int next_idx = (signer_idx + 1) % ring_size;
    c_values[next_idx] = BN_new();
    if (!c_values[next_idx]) { LOGE("BN_new 失敗 (c_values)"); goto cleanup; }
    hash_for_ring(msg, msg_len, L, group, c_values[next_idx], ctx);

    /* 3. ハッシュチェーンを計算する（k+1 から巡回） */
    for (int i = 1; i < ring_size; ++i) {
        int current_idx = (signer_idx + i) % ring_size;
        next_idx = (current_idx + 1) % ring_size;

        const EC_POINT* P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[current_idx]));

        // L = G*s_i + P_i*c_i
        if (!EC_POINT_mul(group, L, s_values[current_idx], P, c_values[current_idx], ctx)) {
            LOGE("EC_POINT_mul 失敗");
            goto cleanup;
        }

        c_values[next_idx] = BN_new();
        if (!c_values[next_idx]) { LOGE("BN_new 失敗 (c_values loop)"); goto cleanup; }
        hash_for_ring(msg, msg_len, L, group, c_values[next_idx], ctx);
    }

    /* 4. s_k を計算し，チェーンを閉じる */
    s_values[signer_idx] = BN_new();
    BIGNUM* tmp = BN_CTX_get(ctx);
    if (!s_values[signer_idx] || !tmp) { LOGE("メモリ確保失敗 2"); goto cleanup; }

    BN_mod_mul(tmp, c_values[signer_idx], priv_bn, order, ctx);
    BN_mod_sub(s_values[signer_idx], alpha, tmp, order, ctx);

    /* 5. 署名を (c0 || s0 || ... || s_{n-1}) として出力する */
    BN_bn2binpad(c_values[0], out_signature, HASH_LEN);
    for (int i = 0; i < ring_size; ++i) {
        BN_bn2binpad(s_values[i], out_signature + (i + 1) * HASH_LEN, HASH_LEN);
    }

    ret = 1;
    LOGI("create_ring_signature: 正常終了");

    cleanup:
    if (ret == 0) {
        LOGE("create_ring_signature: エラーにより処理中断。");
    }
    if (ctx) { BN_CTX_end(ctx); BN_CTX_free(ctx); }
    if (priv_bn) BN_free(priv_bn);
    if (ring_pkeys) {
        for (int i = 0; i < ring_size; ++i) if (ring_pkeys[i]) EVP_PKEY_free(ring_pkeys[i]);
        free(ring_pkeys);
    }
    if (c_values) {
        for (int i = 0; i < ring_size; ++i) if (c_values[i]) BN_free(c_values[i]);
        free(c_values);
    }
    if (s_values) {
        for (int i = 0; i < ring_size; ++i) if (s_values[i]) BN_free(s_values[i]);
        free(s_values);
    }
    if (L) EC_POINT_free(L);
    return ret;
}

EXPORT int verify_ring_signature(
        const char* msg,
        size_t msg_len,
        const uint8_t* signature,
        const uint8_t* ring_pub_keys,
        int ring_size
) {
    if (ring_size < 2) return 0;

    int ret = 0;

    BN_CTX* ctx = NULL;
    EVP_PKEY** ring_pkeys = NULL;
    BIGNUM** s_values = NULL;
    BIGNUM* c0 = NULL;
    BIGNUM* C_calc = NULL;
    EC_POINT* L = NULL;
    const EC_GROUP* group = NULL;

    ctx = BN_CTX_new();
    if (!ctx) goto cleanup;

    ring_pkeys = (EVP_PKEY**)calloc(ring_size, sizeof(EVP_PKEY*));
    s_values = (BIGNUM**)calloc(ring_size, sizeof(BIGNUM*));
    if (!ring_pkeys || !s_values) goto cleanup;

    c0 = BN_bin2bn(signature, HASH_LEN, NULL);
    C_calc = BN_dup(c0);
    if (!c0 || !C_calc) goto cleanup;

    for (int i = 0; i < ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN, ctx);
        s_values[i] = BN_bin2bn(signature + (i + 1) * HASH_LEN, HASH_LEN, NULL);
        if (!ring_pkeys[i] || !s_values[i]) goto cleanup;
    }

    group = EC_KEY_get0_group(EVP_PKEY_get0_EC_KEY(ring_pkeys[0]));
    L = EC_POINT_new(group);
    if (!L) goto cleanup;

    /*
     * 検証:
     * c0 から開始し，L_i = G*s_i + P_i*c_i を順に計算して c_{i+1}=H(m,L_i) を得る。
     * 最後に得られる c_n が c0 と一致すれば有効と判定する。
     */
    for (int i = 0; i < ring_size; ++i) {
        const EC_POINT *P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[i]));
        if (!EC_POINT_mul(group, L, s_values[i], P, C_calc, ctx)) goto cleanup;
        hash_for_ring(msg, msg_len, L, group, C_calc, ctx);
    }

    if (BN_cmp(c0, C_calc) == 0) {
        ret = 1;
    }

    cleanup:
    if (ctx) BN_CTX_free(ctx);
    if (c0) BN_free(c0);
    if (C_calc) BN_free(C_calc);
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
