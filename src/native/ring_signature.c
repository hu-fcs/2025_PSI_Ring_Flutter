#include "ring_signature.h"
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/err.h>

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

static void hash_for_ring(const char *msg, size_t msg_len, const EC_POINT *point, const EC_GROUP *group, BIGNUM *result) {
    size_t len = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, NULL, 0, NULL);
    unsigned char *buf = malloc(len);
    EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, buf, len, NULL);
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
    if (ring_size < 2) return 0;

    int signer_idx = -1;
    BIGNUM* priv_bn = BN_bin2bn(signer_priv_key_32b, PRIV_KEY_LEN, NULL);
    EVP_PKEY** ring_pkeys = calloc(ring_size, sizeof(EVP_PKEY*));
    if (!ring_pkeys || !priv_bn) goto setup_error;

    for (int i=0; i < ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN);
        if (!ring_pkeys[i]) goto setup_error;
    }

    EC_KEY* temp_ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    const EC_GROUP* group = EC_KEY_get0_group(temp_ec_key);
    EC_POINT* pub_point = EC_POINT_new(group);
    EC_POINT_mul(group, pub_point, priv_bn, NULL, NULL, NULL);

    uint8_t signer_pub_key_buf[PUB_KEY_LEN];
    EC_POINT_point2oct(group, pub_point, POINT_CONVERSION_UNCOMPRESSED, signer_pub_key_buf, PUB_KEY_LEN, NULL);

    for(int i=0; i<ring_size; ++i) {
        if(memcmp(signer_pub_key_buf, ring_pub_keys + i * PUB_KEY_LEN, PUB_KEY_LEN) == 0) {
            signer_idx = i;
            break;
        }
    }

    EC_KEY_free(temp_ec_key);
    EC_POINT_free(pub_point);

    if (signer_idx == -1) goto setup_error;

    BN_CTX *ctx = BN_CTX_new();
    const BIGNUM *order = EC_GROUP_get0_order(group);
    BIGNUM *alpha = BN_new();
    BN_rand_range(alpha, order);

    EC_POINT *L = EC_POINT_new(group);
    EC_POINT_mul(group, L, alpha, NULL, NULL, ctx);
    BIGNUM *C = BN_new();
    hash_for_ring(msg, msg_len, L, group, C);

    BIGNUM** s_values = calloc(ring_size, sizeof(BIGNUM*));

    for (int i = 1; i < ring_size; ++i) {
        int cur = (signer_idx + i) % ring_size;
        s_values[cur] = BN_new();
        BN_rand_range(s_values[cur], order);
        const EC_POINT *P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[cur]));
        EC_POINT_mul(group, L, s_values[cur], P, C, ctx);
        hash_for_ring(msg, msg_len, L, group, C);
    }

    BIGNUM *c0_final = BN_dup(C);

    s_values[signer_idx] = BN_new();
    BIGNUM *tmp = BN_new();
    BN_mod_mul(tmp, C, priv_bn, order, ctx);
    BN_mod_sub(s_values[signer_idx], alpha, tmp, order, ctx);

    BN_bn2binpad(c0_final, out_signature, HASH_LEN);
    for(int i=0; i<ring_size; ++i) {
        BN_bn2binpad(s_values[i], out_signature + (i+1)*HASH_LEN, HASH_LEN);
    }

    BN_free(priv_bn); BN_free(alpha); BN_free(C); BN_free(c0_final); BN_free(tmp);
    for(int i=0; i<ring_size; ++i) BN_free(s_values[i]);
    free(s_values);
    EC_POINT_free(L); BN_CTX_free(ctx);
    for(int i=0; i<ring_size; ++i) EVP_PKEY_free(ring_pkeys[i]);
    free(ring_pkeys);
    return 1;

    setup_error:
    if (priv_bn) BN_free(priv_bn);
    for(int i=0; i<ring_size; ++i) if(ring_pkeys && ring_pkeys[i]) EVP_PKEY_free(ring_pkeys[i]);
    if(ring_pkeys) free(ring_pkeys);
    return 0;
}

EXPORT int verify_ring_signature(const char* msg, size_t msg_len, const uint8_t* signature, const uint8_t* ring_pub_keys, int ring_size) {
    EVP_PKEY** ring_pkeys = calloc(ring_size, sizeof(EVP_PKEY*));
    BIGNUM** s_values = calloc(ring_size, sizeof(BIGNUM*));
    BIGNUM* c0 = BN_bin2bn(signature, HASH_LEN, NULL);
    BIGNUM* C = BN_dup(c0);
    int ok = 0;
    BN_CTX *ctx = NULL;
    EC_POINT *L = NULL;

    if (!c0 || !C) goto cleanup;

    for(int i=0; i<ring_size; ++i) {
        ring_pkeys[i] = pkey_from_pub_bytes(ring_pub_keys + i * PUB_KEY_LEN);
        s_values[i] = BN_bin2bn(signature + (i+1)*HASH_LEN, HASH_LEN, NULL);
        if (!ring_pkeys[i] || !s_values[i]) goto cleanup;
    }

    ctx = BN_CTX_new();
    const EC_GROUP *group = EC_KEY_get0_group(EVP_PKEY_get0_EC_KEY(ring_pkeys[0]));
    L = EC_POINT_new(group);
    if(!ctx || !L) goto cleanup;

    for (int i = 0; i < ring_size; ++i) {
        const EC_POINT *P = EC_KEY_get0_public_key(EVP_PKEY_get0_EC_KEY(ring_pkeys[i]));
        EC_POINT_mul(group, L, s_values[i], P, C, ctx);
        hash_for_ring(msg, msg_len, L, group, C);
    }

    ok = (BN_cmp(c0, C) == 0);

    cleanup:
    if (c0) BN_free(c0);
    if (C) BN_free(C);
    if (ring_pkeys) {
        for(int i=0; i<ring_size; ++i) if(ring_pkeys[i]) EVP_PKEY_free(ring_pkeys[i]);
        free(ring_pkeys);
    }
    if (s_values) {
        for(int i=0; i<ring_size; ++i) if(s_values[i]) BN_free(s_values[i]);
        free(s_values);
    }
    if(ctx) BN_CTX_free(ctx);
    if(L) EC_POINT_free(L);

    return ok;
}