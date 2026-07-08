#ifndef ECDSA_H
#define ECDSA_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

/* 定数 */
#define HASH_LEN 32
#define PRIV_KEY_LEN 32
#define PUB_KEY_LEN 33 /* 圧縮公開鍵 (0x02/0x03 + X座標32B) */

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

#endif // ECDSA_H
