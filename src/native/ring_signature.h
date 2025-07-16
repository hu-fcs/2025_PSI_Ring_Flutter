#ifndef RING_SIGNATURE_H
#define RING_SIGNATURE_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

// --- 定数定義 ---
#define HASH_LEN 32
#define PRIV_KEY_LEN 32
#define PUB_KEY_LEN 65 // Uncompressed format

/**
 * @brief リング署名を生成する。
 * @param msg 入力: 署名対象のメッセージ。
 * @param msg_len 入力: メッセージの長さ。
 * @param signer_priv_key_32b 入力: 署名者の32バイトの秘密鍵。
 * @param ring_pub_keys 入力: リングを構成する公開鍵のリスト。(ring_size * PUB_KEY_LEN) バイト。
 * @param ring_size 入力: リングのサイズ。
 * @param out_signature 出力: 生成された署名を格納するバッファ。サイズは (1 + ring_size) * HASH_LEN バイト必要。
 * @return 成功した場合は1、失敗した場合は0。
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
 * @param msg 入力: 署名対象のメッセージ。
 * @param msg_len 入力: メッセージの長さ。
 * @param signature 入力: 検証する署名データ。サイズは (1 + ring_size) * HASH_LEN バイト。
 * @param ring_pub_keys 入力: リングを構成する公開鍵のリスト。(ring_size * PUB_KEY_LEN) バイト。
 * @param ring_size 入力: リングのサイズ。
 * @return 検証に成功した場合は1、失敗した場合は0。
 */
EXPORT int verify_ring_signature(
        const char* msg,
        size_t msg_len,
        const uint8_t* signature,
        const uint8_t* ring_pub_keys,
        int ring_size
);

#endif // RING_SIGNATURE_H
