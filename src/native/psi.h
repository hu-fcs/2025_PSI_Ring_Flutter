#ifndef PSI_H
#define PSI_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

// --- 定数定義 ---
#define HASH_LEN 32
#define PUB_KEY_LEN 65 // Uncompressed format: 0x04 + 32-byte X + 32-byte Y

// --- PSIコンテキスト管理 ---

// PSI計算で使われる各種リソースを管理する不透明な構造体ポインタ
typedef struct PsiContext PsiContext;

/**
 * @brief PSI計算用のコンテキストを新規作成する。
 * @return 成功した場合はPsiContextへのポインタ、失敗した場合はNULL。
 */
EXPORT PsiContext* psi_context_new();

/**
 * @brief psi_context_newで作成したコンテキストを解放する。
 * @param ctx 解放するPsiContextのポインタ。
 */
EXPORT void psi_context_free(PsiContext* ctx);

/**
 * @brief コンテキストから内部で生成された法（modulus）を取得する。
 * @param ctx PsiContextのポインタ。
 * @param out_modulus_32b 出力: 32バイトの法の値を格納するバッファ。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int psi_context_get_modulus(PsiContext* ctx, uint8_t* out_modulus_32b);

/**
 * @brief 外部から法（modulus）を設定する。
 * @param ctx PsiContextのポインタ。
 * @param modulus_32b 入力: 設定する32バイトの法の値。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int psi_context_set_modulus(PsiContext* ctx, const uint8_t* modulus_32b);


// --- PSI関連関数 ---

/**
 * @brief 公開鍵のリストをハッシュ化し、指定された秘密の値で暗号化する。
 * @param ctx PsiContextのポインタ。
 * @param pub_keys 入力: 公開鍵のリスト。 (count * PUB_KEY_LEN) バイト。
 * @param count 入力: 公開鍵の数。
 * @param secret_32b 入力: 暗号化に用いる32バイトの秘密の値。
 * @param out_encrypted_hashes 出力: 暗号化されたハッシュのリストを格納するバッファ。(count * HASH_LEN) バイト。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int hash_and_encrypt_pubkey_set(
        PsiContext* ctx,
        const uint8_t* pub_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_encrypted_hashes
);

/**
 * @brief ハッシュ化された値のリストを、指定された秘密の値でさらに暗号化する。
 * @param ctx PsiContextのポインタ。
 * @param input_hashes 入力: ハッシュのリスト。(count * HASH_LEN) バイト。
 * @param count 入力: ハッシュの数。
 * @param secret_32b 入力: 暗号化に用いる32バイトの秘密の値。
 * @param out_encrypted_hashes 出力: 再暗号化されたハッシュのリストを格納するバッファ。(count * HASH_LEN) バイト。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int encrypt_hash_set(
        PsiContext* ctx,
        const uint8_t* input_hashes,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_encrypted_hashes
);

#endif // PSI_H