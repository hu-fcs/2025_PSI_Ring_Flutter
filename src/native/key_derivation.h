#ifndef KEY_DERIVATION_H
#define KEY_DERIVATION_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

EXPORT int generate_master_key(
        uint8_t* out_master_key_32b
);

/**
 * @brief マスターキーとタイムスタンプから鍵ペアを導出する。
 *
 * @param master_key       入力: 32バイトのマスターキー。
 * @param timestamp_ms     入力: 鍵導出の元となるタイムスタンプ（ミリ秒）。
 * @param slot_ms          入力: タイムスロットの間隔（ミリ秒）。
 * @param out_priv_key_32b 出力: 生成された32バイトの秘密鍵を格納するバッファ。
 * @param out_pub_key_65b  出力: 生成された33バイトの圧縮公開鍵を格納するバッファ。
 * @return 成功した場合は 1、失敗した場合は 0。
 */
EXPORT int derive_keypair_from_timestamp(
        const uint8_t* master_key,
        uint64_t timestamp_ms,
        uint64_t slot_ms,
        uint8_t* out_priv_key_32b,
        uint8_t* out_pub_key_33b
);

#endif // KEY_DERIVATION_H