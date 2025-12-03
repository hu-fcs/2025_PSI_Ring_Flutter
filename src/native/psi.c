#include "psi.h"
#include <stdlib.h>
#include <string.h>

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

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/bn.h>
#include <openssl/obj_mac.h>

static EC_GROUP* g_curve_group = NULL;

EXPORT int psi_init() {
    if (g_curve_group) return 1;
    g_curve_group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    if (!g_curve_group) {
        LOGE("psi_init: EC_GROUP作成失敗");
        return 0;
    }
    return 1;
}

EXPORT void psi_cleanup() {
    if (g_curve_group) {
        EC_GROUP_free(g_curve_group);
        g_curve_group = NULL;
    }
}

// ★追加実装: ダミー鍵生成
EXPORT int generate_random_dummy_key_bytes(uint8_t* out33b) {
    if (!g_curve_group && !psi_init()) return 0;

    EC_KEY* pkey = EC_KEY_new();
    EC_KEY_set_group(pkey, g_curve_group);

    if (!EC_KEY_generate_key(pkey)) {
        EC_KEY_free(pkey);
        return 0;
    }

    const EC_POINT* pub = EC_KEY_get0_public_key(pkey);
    size_t len = EC_POINT_point2oct(g_curve_group, pub, POINT_CONVERSION_COMPRESSED, out33b, PUB_KEY_LEN, NULL);

    EC_KEY_free(pkey);
    return (len == PUB_KEY_LEN) ? 1 : 0;
}

// 内部ヘルパー
static int ecc_point_mul(const uint8_t* input_33b, const uint8_t* secret_32b, uint8_t* output_33b) {
    if (!g_curve_group) return 0;

    BN_CTX *ctx = BN_CTX_new();
    EC_POINT *point = EC_POINT_new(g_curve_group);
    EC_POINT *result = EC_POINT_new(g_curve_group);
    BIGNUM *scalar = BN_bin2bn(secret_32b, PRIV_KEY_LEN, NULL);
    int ret = 0;

    if (ctx && point && result && scalar) {
        if (EC_POINT_oct2point(g_curve_group, point, input_33b, PUB_KEY_LEN, ctx) &&
            EC_POINT_mul(g_curve_group, result, NULL, point, scalar, ctx) &&
            EC_POINT_point2oct(g_curve_group, result, POINT_CONVERSION_COMPRESSED, output_33b, PUB_KEY_LEN, ctx) == PUB_KEY_LEN) {
            ret = 1;
        }
    }

    if (scalar) BN_free(scalar);
    if (point) EC_POINT_free(point);
    if (result) EC_POINT_free(result);
    if (ctx) BN_CTX_free(ctx);
    return ret;
}

EXPORT int ecc_single_encrypt_set(const uint8_t* input_keys, int count, const uint8_t* secret_32b, uint8_t* out_keys) {
    if (!input_keys || !secret_32b || !out_keys) return 0;
    if (!g_curve_group && !psi_init()) return 0;

    for (int i = 0; i < count; ++i) {
        const uint8_t* in = input_keys + (size_t)i * PUB_KEY_LEN;
        uint8_t* out = out_keys + (size_t)i * PUB_KEY_LEN;
        if (!ecc_point_mul(in, secret_32b, out)) {
            memset(out, 0, PUB_KEY_LEN);
            return 0;
        }
    }
    return 1;
}

EXPORT int ecc_intersect_sets(const uint8_t* original_keys, const uint8_t* my_double_set, const uint8_t* remote_double_set, int count_a, int count_b, uint8_t* result_keys, int* result_count) {
    if (!original_keys || !my_double_set || !remote_double_set || !result_keys || !result_count) return 0;

    int found = 0;
    for (int i = 0; i < count_a; i++) {
        const uint8_t* my_dbl = my_double_set + (size_t)i * PUB_KEY_LEN;
        int matched = 0;
        for (int j = 0; j < count_b; j++) {
            const uint8_t* remote_dbl = remote_double_set + (size_t)j * PUB_KEY_LEN;
            if (memcmp(my_dbl, remote_dbl, PUB_KEY_LEN) == 0) {
                matched = 1;
                break;
            }
        }
        if (matched) {
            const uint8_t* original_key = original_keys + (size_t)i * PUB_KEY_LEN;
            memcpy(result_keys + (size_t)found * PUB_KEY_LEN, original_key, PUB_KEY_LEN);
            found++;
        }
    }
    *result_count = found;
    return 1;
}