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
// 圧縮形式 (0x02/0x03 + 32-byte X) を採用
#define PUB_KEY_LEN 33

/**
 * @brief リング署名を生成する。
 * @param msg 入力: 署名対象のメッセージ。
 * @param msg_len 入力: メッセージの長さ。
 * @param signer_priv_key_32b 入力: 署名者の32バイトの秘密鍵。
 * @param ring_pub_keys 入力: リングを構成する公開鍵のリスト（圧縮形式33B）。(ring_size * PUB_KEY_LEN) バイト。
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
 * @param ring_pub_keys 入力: リングを構成する公開鍵のリスト（圧縮形式33B）。(ring_size * PUB_KEY_LEN) バイト。
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

// ECDSA チャレンジ署名 (secp256r1)
// out_sig64 は 64 bytes (r||s)
EXPORT int ecdsa_sign_challenge(
        const uint8_t* priv_key_32b,
        const uint8_t* msg,
        uint32_t msg_len,
        uint8_t* out_sig64);

// ECDSA チャレンジ検証 (secp256r1)
// sig64 は 64 bytes (r||s)
EXPORT int ecdsa_verify_challenge(
        const uint8_t* pub_key_33b,
        const uint8_t* msg,
        uint32_t msg_len,
        const uint8_t* sig64);

#endif // RING_SIGNATURE_H
