#ifndef KEY_DERIVATION_H
#define KEY_DERIVATION_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else // iOS（stripで削除されないように）
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/**
 * @brief 32バイトのマスターキーを生成する。
 *
 * @param out_master_key_32b 出力: マスターキー(32B)を書き込むバッファ。
 * @return 成功時は 1，失敗時は 0。
 */
EXPORT int generate_master_key(
        uint8_t* out_master_key_32b
);

/**
 * @brief マスターキーと時刻スロットから鍵ペアを導出する。
 *
 * timestamp_ms を slot_ms で丸めたスロット開始時刻に基づいて鍵を導出する。
 *
 * @param master_key        入力: マスターキー(32B)。
 * @param timestamp_ms      入力: 時刻（ミリ秒）。
 * @param slot_ms           入力: 時刻スロット幅（ミリ秒）。
 * @param out_priv_key_32b  出力: 秘密鍵(32B)を書き込むバッファ。
 * @param out_pub_key_33b   出力: 圧縮公開鍵(33B)を書き込むバッファ。
 * @return 成功時は 1，失敗時は 0。
 */
EXPORT int derive_keypair_from_timestamp(
        const uint8_t* master_key,
        uint64_t timestamp_ms,
        uint64_t slot_ms,
        uint8_t* out_priv_key_32b,
        uint8_t* out_pub_key_33b
);

#endif // KEY_DERIVATION_H
