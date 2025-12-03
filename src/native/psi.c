#include "psi.h"
#include <stdlib.h>
#include <string.h>
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/bn.h>
#include <openssl/obj_mac.h>

// --- 内部リソース管理 ---

// ECCグループをグローバルな静的変数として保持
static EC_GROUP* curve_group = NULL;

// --- 内部ヘルパー関数 ---

// 単一の点乗算: Result = Secret * Point (ECC-PSIのコア処理)
static int ecc_point_mul(const uint8_t* input_33b, const uint8_t* secret_32b, uint8_t* output_33b) {
    if (!curve_group) return 0; // 未初期化エラー

    BN_CTX *tmp_ctx = BN_CTX_new();
    EC_POINT *point = EC_POINT_new(curve_group);
    EC_POINT *result = EC_POINT_new(curve_group);
    BIGNUM *scalar = BN_bin2bn(secret_32b, PRIV_KEY_LEN, NULL);
    int success = 0;

    if (!tmp_ctx || !point || !result || !scalar) goto cleanup;

    // 圧縮鍵を点に変換
    if (!EC_POINT_oct2point(curve_group, point, input_33b, PUB_KEY_LEN, tmp_ctx)) goto cleanup;

    // 点乗算: result = scalar * point
    if (!EC_POINT_mul(curve_group, result, NULL, point, scalar, tmp_ctx)) goto cleanup;

    // 結果を圧縮鍵に戻す (33B)
    if (EC_POINT_point2oct(curve_group, result, POINT_CONVERSION_COMPRESSED, output_33b, PUB_KEY_LEN, tmp_ctx) == PUB_KEY_LEN) {
        success = 1;
    }

    cleanup:
    BN_free(scalar);
    EC_POINT_free(point);
    EC_POINT_free(result);
    if (tmp_ctx) BN_CTX_free(tmp_ctx);
    return success;
}


// --- 公開APIの実装 (リソース管理) ---

/**
 * @brief PSI計算に必要なECCリソース（曲線の情報など）を初期化する。
 */
EXPORT int psi_init() {
    if (curve_group) return 1; // 既に初期化済み

    // P-256 (prime256v1) ECグループを初期化
    curve_group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);

    if (!curve_group) {
        return 0; // 初期化失敗
    }
    return 1;
}

/**
 * @brief psi_initで作成したリソースを解放する。
 */
EXPORT void psi_cleanup() {
    if (curve_group) {
        EC_GROUP_free(curve_group);
        curve_group = NULL;
    }
}


// --- 公開APIの実装 (PSIロジック) ---

/**
 * @brief 公開鍵のリストを秘密の値で暗号化/再暗号化する。(ECC: P -> aP または aP -> b(aP))
 */
EXPORT int ecc_encrypt_set(
        const uint8_t* pub_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_encrypted_keys
) {
    if (!pub_keys || !secret_32b || !out_encrypted_keys) return 0;
    if (!curve_group) return 0; // 未初期化エラー

    for (int i = 0; i < count; ++i) {
        const uint8_t* in = pub_keys + (size_t)i * PUB_KEY_LEN;
        uint8_t* out = out_encrypted_keys + (size_t)i * PUB_KEY_LEN;

        // 秘密スカラー * 点 (P -> aP, aP -> b(aP) など)
        if (!ecc_point_mul(in, secret_32b, out)) {
            // 失敗時は0で埋める
            memset(out, 0, PUB_KEY_LEN);
            return 0; // 一つでも失敗したら全体を失敗とする
        }
    }
    return 1;
}


/**
 * @brief 二重暗号化された公開鍵リストを比較し、共通集合に対応する元の公開鍵を復元する。
 */
EXPORT int ecc_intersect_sets(
        const uint8_t* original_keys,
        const uint8_t* my_double_set,
        const uint8_t* remote_double_set,
        int count_a,
        int count_b,
        uint8_t* result_keys,
        int* result_count
) {
    if (!original_keys || !my_double_set || !remote_double_set || !result_keys || !result_count) return 0;
    if (!curve_group) return 0; // 未初期化エラー

    int found = 0;

    // my_double_set (abP) と remote_double_set (abQ) の要素を比較
    for (int i = 0; i < count_a; i++) {
        const uint8_t* my_dbl = my_double_set + (size_t)i * PUB_KEY_LEN;

        int matched = 0;
        for (int j = 0; j < count_b; j++) {
            const uint8_t* remote_dbl = remote_double_set + (size_t)j * PUB_KEY_LEN;

            // 33バイト完全一致なら、共通集合要素
            if (memcmp(my_dbl, remote_dbl, PUB_KEY_LEN) == 0) {
                matched = 1;
                break;
            }
        }

        if (matched) {
            // マッチした場合、元の公開鍵 P を結果リストに追加
            const uint8_t* original_key = original_keys + (size_t)i * PUB_KEY_LEN;
            memcpy(result_keys + (size_t)found * PUB_KEY_LEN, original_key, PUB_KEY_LEN);
            found++;
        }
    }
    *result_count = found;
    return 1;
}