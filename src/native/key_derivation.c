#include "key_derivation.h"
#include <string.h>

#include <openssl/rand.h>
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/ec.h>
#include <openssl/bn.h>

#define HASH_LEN 32

/**
 * @brief 32バイトのマスターキーを生成する。
 *
 * OpenSSL の RAND_bytes を用いる。
 */
int generate_master_key(uint8_t* out_master_key_32b) {
    return RAND_bytes(out_master_key_32b, HASH_LEN);
}

/**
 * @brief マスターキーと時刻スロットから ECDSA 鍵対を導出する。
 *
 * timestamp_ms を slot_ms で丸めたスロット開始時刻を salt に用い，
 * HKDF-SHA256 で秘密鍵素材(32B)を導出する。
 *
 * 公開鍵は圧縮形式(33B: 0x02/0x03 + X座標32B)で出力する。
 */
int derive_keypair_from_timestamp(
        const uint8_t* master_key,
        uint64_t timestamp_ms,
        uint64_t slot_ms,
        uint8_t* out_priv_key_32b,
        uint8_t* out_pub_key_33b
) {
    EVP_PKEY_CTX* pctx = NULL;
    EC_KEY* ec_key = NULL;
    BIGNUM* priv_bn = NULL;
    const EC_GROUP* group = NULL;
    EC_POINT* pub_point = NULL;
    BN_CTX* bn_ctx = NULL;
    int ret = 0;

    if (slot_ms == 0) {
        return 0;
    }

    const uint64_t slot_time = (timestamp_ms / slot_ms) * slot_ms;

    // HKDF の salt: スロット開始時刻(64bit)を big-endian で格納
    uint8_t salt[8];
    for (int i = 0; i < 8; i++) {
        salt[7 - i] = (uint8_t)((slot_time >> (8 * i)) & 0xFF);
    }

    // 用途識別子（HKDF info）
    const char* info_str = "ecdsakey";
    uint8_t derived_priv_bytes[HASH_LEN];

    // HKDF-SHA256(master_key, salt, info) -> 32B
    pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
    if (!pctx) goto cleanup;
    if (EVP_PKEY_derive_init(pctx) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set_hkdf_md(pctx, EVP_sha256()) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set1_hkdf_salt(pctx, salt, (int)sizeof(salt)) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_set1_hkdf_key(pctx, master_key, HASH_LEN) <= 0) goto cleanup;
    if (EVP_PKEY_CTX_add1_hkdf_info(pctx, (const void*)info_str, (int)strlen(info_str)) <= 0) goto cleanup;

    size_t derived_len = HASH_LEN;
    if (EVP_PKEY_derive(pctx, derived_priv_bytes, &derived_len) <= 0) goto cleanup;
    if (derived_len != HASH_LEN) goto cleanup;

    // secp256r1 (prime256v1) 上で鍵対を構成する
    ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec_key) goto cleanup;

    priv_bn = BN_bin2bn(derived_priv_bytes, HASH_LEN, NULL);
    if (!priv_bn) goto cleanup;

    group = EC_KEY_get0_group(ec_key);
    pub_point = EC_POINT_new(group);
    bn_ctx = BN_CTX_new();
    if (!pub_point || !bn_ctx) goto cleanup;

    // pub = priv * G
    if (!EC_POINT_mul(group, pub_point, priv_bn, NULL, NULL, bn_ctx)) goto cleanup;

    if (!EC_KEY_set_private_key(ec_key, priv_bn)) goto cleanup;
    if (!EC_KEY_set_public_key(ec_key, pub_point)) goto cleanup;

    // 秘密鍵(32B)
    if (BN_bn2binpad(priv_bn, out_priv_key_32b, 32) != 32) goto cleanup;

    // 公開鍵(圧縮 33B)
    const size_t need = EC_POINT_point2oct(
            group,
            pub_point,
            POINT_CONVERSION_COMPRESSED,
            NULL,
            0,
            bn_ctx
    );
    if (need != 33) goto cleanup;

    if (EC_POINT_point2oct(
            group,
            pub_point,
            POINT_CONVERSION_COMPRESSED,
            out_pub_key_33b,
            33,
            bn_ctx
    ) != 33) {
        goto cleanup;
    }

    ret = 1;

    cleanup:
    if (pctx) EVP_PKEY_CTX_free(pctx);
    if (ec_key) EC_KEY_free(ec_key);
    if (priv_bn) BN_free(priv_bn);
    if (pub_point) EC_POINT_free(pub_point);
    if (bn_ctx) BN_CTX_free(bn_ctx);

    return ret;
}
