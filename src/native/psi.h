#ifndef PSI_H
#define PSI_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

// --- 定数 ---
#define PUB_KEY_LEN 33   // 圧縮公開鍵 (0x02/0x03 + 32-byte X)
#define PRIV_KEY_LEN 32  // 秘密スカラー長（32バイト）

// --- 初期化 / 終了 ---
EXPORT int psi_init();
EXPORT void psi_cleanup();

// -----------------------------------------------------------
// ECC PSI のみ提供（鍵生成は Flutter 側で行う）
// -----------------------------------------------------------

/**
 * @brief 与えられた鍵集合 input_keys[] に対して
 *        secret_32b を掛けて暗号化する (aP, bQ)
 *
 * @param input_keys  フラットな鍵配列（33 * count bytes）
 * @param count       鍵数
 * @param secret_32b  32バイト秘密スカラー
 * @param out_keys    出力 (33 * count bytes)
 * @return 1 success, 0 failure
 */
EXPORT int ecc_single_encrypt_set(
        const uint8_t* input_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_keys
);

/**
 * @brief PSI の共通集合抽出 (abP vs abQ)
 *
 * original_keys      元の鍵 P または Q（33 * count_a）
 * my_double_set      自分側の abP または abQ
 * remote_double_set  相手側の abP または abQ
 *
 * result_keys        共通した元の鍵がここにコピーされる（33 * result_count）
 * result_count       共通鍵数（出力）
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
