#ifndef PSI_H
#define PSI_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* 定数 */
#define PUB_KEY_LEN 33   /* 圧縮公開鍵 (0x02/0x03 + X座標32B) */
#define PRIV_KEY_LEN 32  /* 秘密スカラー長 (32B) */

/* 初期化 / 終了 */
EXPORT int psi_init();
EXPORT void psi_cleanup();

/*
 * 本モジュールは ECC PSI の計算のみを提供する。
 * 鍵生成および鍵管理はアプリケーション側（Flutter）で行う。
 */

/**
 * @brief 鍵集合 input_keys を secret_32b でスカラー倍し，暗号化集合を得る。
 *
 * @param input_keys  入力: 鍵配列（33 * count bytes）
 * @param count       入力: 鍵数
 * @param secret_32b  入力: 秘密スカラー（32B）
 * @param out_keys    出力: 暗号化後の鍵配列（33 * count bytes）
 * @return 成功時は 1，失敗時は 0。
 */
EXPORT int ecc_single_encrypt_set(
        const uint8_t* input_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_keys
);

/**
 * @brief PSI の共通集合を抽出する（abP と abQ の一致判定）。
 *
 * @param original_keys      入力: 元の鍵列 P（33 * count_a bytes）
 * @param my_double_set      入力: 自分側の二重暗号化鍵列（abP）
 * @param remote_double_set  入力: 相手側の二重暗号化鍵列（abQ）
 * @param count_a            入力: original_keys / my_double_set の要素数
 * @param count_b            入力: remote_double_set の要素数
 * @param result_keys        出力: 共通した元の鍵列（33 * result_count bytes）
 * @param result_count       出力: 共通要素数
 * @return 成功時は 1，失敗時は 0。
 */
EXPORT int ecc_intersect_sets(
        const uint8_t* original_keys,
        const uint8_t* my_double_set,
        const uint8_t* remote_double_set,
        int count_a,
        int count_b,
        uint8_t* result_keys,
        int* result_count
);

#endif // PSI_H
