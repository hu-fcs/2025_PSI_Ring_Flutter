#include "psi.h"
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/crypto.h>

// --- 内部構造体 ---
struct PsiContext {
    BIGNUM *p_modulus;
    BN_CTX *bn_ctx;
};

// --- 内部ヘルパー関数 ---

static EVP_PKEY* pkey_from_pub_bytes(const uint8_t* pub_key_bytes) {
    EVP_PKEY* pkey = NULL;
    EC_KEY* ec_key = NULL;
    const EC_GROUP* group = NULL;
    EC_POINT* pub_point = NULL;

    ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec_key) goto cleanup;

    group = EC_KEY_get0_group(ec_key);
    pub_point = EC_POINT_new(group);
    if (!pub_point) goto cleanup;

    if (!EC_POINT_oct2point(group, pub_point, pub_key_bytes, PUB_KEY_LEN, NULL)) goto cleanup;
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

static int hash_public_key(const uint8_t* pub_key_bytes, uint8_t* digest) {
    EVP_PKEY* pkey = pkey_from_pub_bytes(pub_key_bytes);
    if (!pkey) return 0;

    unsigned char *pubkey_der = NULL;
    int len = i2d_PublicKey(pkey, &pubkey_der);
    if (len <= 0) {
        EVP_PKEY_free(pkey);
        return 0;
    }
    SHA256(pubkey_der, len, digest);
    OPENSSL_free(pubkey_der);
    EVP_PKEY_free(pkey);
    return 1;
}

static void power_encrypt_single(PsiContext* ctx, const uint8_t *base_val, const uint8_t *exponent_val, uint8_t *result) {
    BIGNUM *base = BN_bin2bn(base_val, HASH_LEN, NULL);
    BIGNUM *exp = BN_bin2bn(exponent_val, HASH_LEN, NULL);
    BIGNUM *res = BN_new();
    BN_mod_exp(res, base, exp, ctx->p_modulus, ctx->bn_ctx);
    memset(result, 0, HASH_LEN);
    BN_bn2binpad(res, result, HASH_LEN);
    BN_free(base);
    BN_free(exp);
    BN_free(res);
}

// --- 公開APIの実装 ---

EXPORT PsiContext* psi_context_new() {
    PsiContext* ctx = malloc(sizeof(PsiContext));
    if (!ctx) return NULL;

    ctx->p_modulus = BN_new();
    ctx->bn_ctx = BN_CTX_new();
    if (!ctx->p_modulus || !ctx->bn_ctx) {
        psi_context_free(ctx);
        return NULL;
    }
    if (!BN_generate_prime_ex(ctx->p_modulus, 256, 1, NULL, NULL, NULL)) {
        psi_context_free(ctx);
        return NULL;
    }
    return ctx;
}

EXPORT void psi_context_free(PsiContext* ctx) {
    if (!ctx) return;
    if (ctx->p_modulus) BN_free(ctx->p_modulus);
    if (ctx->bn_ctx) BN_CTX_free(ctx->bn_ctx);
    free(ctx);
}

EXPORT int psi_context_get_modulus(PsiContext* ctx, uint8_t* out_modulus_32b) {
    if (!ctx || !ctx->p_modulus || !out_modulus_32b) return 0;
    return BN_bn2binpad(ctx->p_modulus, out_modulus_32b, HASH_LEN);
}

EXPORT int psi_context_set_modulus(PsiContext* ctx, const uint8_t* modulus_32b) {
    if (!ctx || !modulus_32b) return 0;
    if (!BN_bin2bn(modulus_32b, HASH_LEN, ctx->p_modulus)) return 0;
    return 1;
}

EXPORT int hash_and_encrypt_pubkey_set(PsiContext* ctx, const uint8_t* pub_keys, int count, const uint8_t* secret_32b, uint8_t* out_encrypted_hashes) {
    if (!ctx || !pub_keys || !secret_32b || !out_encrypted_hashes) return 0;

    uint8_t temp_hash[HASH_LEN];
    for (int i = 0; i < count; ++i) {
        if (!hash_public_key(pub_keys + i * PUB_KEY_LEN, temp_hash)) {
            return 0;
        }
        power_encrypt_single(ctx, temp_hash, secret_32b, out_encrypted_hashes + i * HASH_LEN);
    }
    return 1;
}

EXPORT int encrypt_hash_set(PsiContext* ctx, const uint8_t* input_hashes, int count, const uint8_t* secret_32b, uint8_t* out_encrypted_hashes) {
    if (!ctx || !input_hashes || !secret_32b || !out_encrypted_hashes) return 0;

    for (int i = 0; i < count; ++i) {
        power_encrypt_single(ctx, input_hashes + i * HASH_LEN, secret_32b, out_encrypted_hashes + i * HASH_LEN);
    }
    return 1;
}