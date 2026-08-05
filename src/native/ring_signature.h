#ifndef RING_SIGNATURE_H
#define RING_SIGNATURE_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else // iOS（stripで削除されないように）
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* 定数 */
#define HASH_LEN 32
#define PRIV_KEY_LEN 32
#define PUB_KEY_LEN 33 /* 圧縮公開鍵 (0x02/0x03 + X座標32B) */

/**
 * @brief リング署名を生成する。
 *
 * 署名形式は (c0 || s0 || ... || s_{n-1}) とし，サイズは (1 + ring_size) * HASH_LEN とする。
 *
 * @param msg                 入力: 署名対象メッセージ。
 * @param msg_len             入力: メッセージ長。
 * @param signer_priv_key_32b 入力: 署名者秘密鍵(32B)。
 * @param ring_pub_keys       入力: リング公開鍵列(圧縮33B)（ring_size * PUB_KEY_LEN B）。
 * @param ring_size           入力: リングサイズ。
 * @param out_signature       出力: 署名出力バッファ（(1 + ring_size) * HASH_LEN B が必要）。
 * @return 成功時は 1，失敗時は 0。
 */
EXPORT int create_ring_signature(
        const char* msg,
        size_t msg_len,
        const uint8_t* signer_priv_key_32b,
        const uint8_t* ring_pub_keys,
        int ring_size,
        uint8_t* out_signature
);

/**
 * @brief リング署名を検証する。
 *
 * @param msg           入力: 署名対象メッセージ。
 * @param msg_len       入力: メッセージ長。
 * @param signature     入力: 署名データ（(1 + ring_size) * HASH_LEN B）。
 * @param ring_pub_keys 入力: リング公開鍵列(圧縮33B)（ring_size * PUB_KEY_LEN B）。
 * @param ring_size     入力: リングサイズ。
 * @return 検証に成功した場合は 1，それ以外は 0。
 */
EXPORT int verify_ring_signature(
        const char* msg,
        size_t msg_len,
        const uint8_t* signature,
        const uint8_t* ring_pub_keys,
        int ring_size
);

#endif // RING_SIGNATURE_H
