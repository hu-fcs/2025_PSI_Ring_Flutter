#include "ring_signature.h"
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/crypto.h>
#include <openssl/ecdsa.h>

#ifdef __ANDROID__
#include <android/log.h>
#define LOG_TAG "PsiECC"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#include <stdio.h>
#define LOGI(...) printf("[INFO] " __VA_ARGS__); printf("\n")
#define LOGE(...) printf("[ERROR] " __VA_ARGS__); printf("\n")
#endif

static EC_KEY* ec_key_from_priv32(const uint8_t* priv_key_32b, BN_CTX* ctx) {
    EC_KEY* ec = NULL;
    BIGNUM* priv_bn = NULL;
    const EC_GROUP* group = NULL;

    ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec) goto err;

    group = EC_KEY_get0_group(ec);
    if (!group) goto err;

    priv_bn = BN_bin2bn(priv_key_32b, PRIV_KEY_LEN, NULL);
    if (!priv_bn) goto err;

    if (!EC_KEY_set_private_key(ec, priv_bn)) goto err;

    // 公開鍵も設定しておく（必須ではないが、念のため）
    EC_POINT* pub = EC_POINT_new(group);
    if (!pub) goto err;

    if (!EC_POINT_mul(group, pub, priv_bn, NULL, NULL, ctx)) {
        EC_POINT_free(pub);
        goto err;
    }
    if (!EC_KEY_set_public_key(ec, pub)) {
        EC_POINT_free(pub);
        goto err;
    }
    EC_POINT_free(pub);

    BN_clear_free(priv_bn);
    return ec;
    err:
    if (priv_bn) BN_clear_free(priv_bn);
    if (ec) EC_KEY_free(ec);
    return NULL;
}

static EC_KEY* ec_key_from_pub33(const uint8_t* pub_key_33b, BN_CTX* ctx) {
    EC_KEY* ec = NULL;
    const EC_GROUP* group = NULL;
    EC_POINT* point = NULL;

    ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec) goto err;

    group = EC_KEY_get0_group(ec);
    if (!group) goto err;

    point = EC_POINT_new(group);
    if (!point) goto err;

    // 圧縮形式(33B)からEC_POINTに復元
    if (!EC_POINT_oct2point(group, point, pub_key_33b, PUB_KEY_LEN, ctx)) {
        goto err;
    }

    if (!EC_KEY_set_public_key(ec, point)) {
        goto err;
    }

    EC_POINT_free(point);
    return ec;
    err:
    if (point) EC_POINT_free(point);
    if (ec) EC_KEY_free(ec);
    return NULL;
}

EXPORT int ecdsa_sign_challenge(
        const uint8_t* priv_key_32b,
        const uint8_t* msg,
        uint32_t msg_len,
        uint8_t* out_sig64)
{
    if (!priv_key_32b || !msg || !out_sig64) {
        return 0;
    }

    int ret = 0;
    BN_CTX* bn_ctx = NULL;
    EC_KEY* ec = NULL;
    ECDSA_SIG* sig = NULL;
    BIGNUM *r = NULL, *s = NULL;
    unsigned char digest[HASH_LEN];

    // 1. msg を SHA-256 でハッシュ
    SHA256(msg, msg_len, digest);

    bn_ctx = BN_CTX_new();
    if (!bn_ctx) goto end;

    // 2. 秘密鍵から EC_KEY を構築
    ec = ec_key_from_priv32(priv_key_32b, bn_ctx);
    if (!ec) goto end;

    // 3. 署名
    sig = ECDSA_do_sign(digest, HASH_LEN, ec);
    if (!sig) goto end;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    r = sig->r;
    s = sig->s;
#else
    ECDSA_SIG_get0(sig, (const BIGNUM**)&r, (const BIGNUM**)&s);
#endif

    // 4. r, s をそれぞれ 32バイトにパディングして out_sig64 に詰める
    if (BN_bn2binpad(r, out_sig64, 32) != 32) goto end;
    if (BN_bn2binpad(s, out_sig64 + 32, 32) != 32) goto end;

    ret = 1;

    end:
    if (sig) ECDSA_SIG_free(sig);
    if (ec) EC_KEY_free(ec);
    if (bn_ctx) BN_CTX_free(bn_ctx);
    OPENSSL_cleanse(digest, sizeof(digest));
    return ret;
}

EXPORT int ecdsa_verify_challenge(
        const uint8_t* pub_key_33b,
        const uint8_t* msg,
        uint32_t msg_len,
        const uint8_t* sig64)
{
    if (!pub_key_33b || !msg || !sig64) {
        return 0;
    }

    int ret = 0;
    BN_CTX* bn_ctx = NULL;
    EC_KEY* ec = NULL;
    ECDSA_SIG* sig = NULL;
    BIGNUM *r = NULL, *s = NULL;
    unsigned char digest[HASH_LEN];

    SHA256(msg, msg_len, digest);

    bn_ctx = BN_CTX_new();
    if (!bn_ctx) goto end;

    ec = ec_key_from_pub33(pub_key_33b, bn_ctx);
    if (!ec) goto end;

    sig = ECDSA_SIG_new();
    if (!sig) goto end;

    r = BN_bin2bn(sig64, 32, NULL);
    s = BN_bin2bn(sig64 + 32, 32, NULL);
    if (!r || !s) goto end;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    sig->r = r;
    sig->s = s;
#else
    if (!ECDSA_SIG_set0(sig, r, s)) goto end;
    // ECDSA_SIG_set0 が成功すると r/s の所有権は sig に移る
    r = s = NULL;
#endif

    // 検証
    ret = ECDSA_do_verify(digest, HASH_LEN, sig, ec);

    end:
    if (r) BN_free(r);
    if (s) BN_free(s);
    if (sig) ECDSA_SIG_free(sig);
    if (ec) EC_KEY_free(ec);
    if (bn_ctx) BN_CTX_free(bn_ctx);
    OPENSSL_cleanse(digest, sizeof(digest));
    return (ret == 1) ? 1 : 0;
}
