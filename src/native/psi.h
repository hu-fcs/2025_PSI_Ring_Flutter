#ifndef PSI_H
#define PSI_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

// --- 定数定義 ---
#define PUB_KEY_LEN 33 // 圧縮形式公開鍵 (0x02/0x03 + 32-byte X)
#define PRIV_KEY_LEN 32 // 秘密スカラー長 (256ビット)

// --- リソース管理 ---
EXPORT int psi_init();
EXPORT void psi_cleanup();

// --- 鍵生成ヘルパー ---
/**
 * @brief ダミー用のランダムな公開鍵（33バイト圧縮形式）を生成する。
 * 秘密鍵は持たない（あるいは破棄された）状態。
 */
EXPORT int generate_random_dummy_key_bytes(uint8_t* out33b);

// --- PSI関連関数 (ECC-PSI) ---
EXPORT int ecc_single_encrypt_set(
        const uint8_t* input_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_keys
);

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