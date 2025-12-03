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
#define PUB_KEY_LEN 33 // 圧縮形式公開鍵 (0x02/0x03 + 32-byte X)
#define PRIV_KEY_LEN 32 // 秘密スカラー長 (256ビット)

// --- PSIリソース管理 ---

/**
 * @brief PSI計算に必要なECCリソース（曲線の情報など）を初期化する。
 * @note グローバルに設定されるため、PSI関数を使う前に一度だけ呼び出す必要がある。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int psi_init();

/**
 * @brief psi_initで作成したリソースを解放する。
 */
EXPORT void psi_cleanup();


// --- PSI関連関数 (ECC-PSIロジック) ---

/**
 * @brief 公開鍵のリストを秘密の値で暗号化/再暗号化する。(ECC: P -> aP)
 * @param pub_keys 入力: 圧縮形式(33B)の公開鍵のリスト。 (count * PUB_KEY_LEN) バイト。
 * @param count 入力: 公開鍵の数。
 * @param secret_32b 入力: 暗号化に用いる32バイトの秘密の値（スカラー）。
 * @param out_encrypted_keys 出力: 暗号化された公開鍵のリストを格納するバッファ。(count * PUB_KEY_LEN) バイト。
 * @return 成功した場合は1、失敗した場合は0。
 */
EXPORT int ecc_encrypt_set(
        const uint8_t* pub_keys,
        int count,
        const uint8_t* secret_32b,
        uint8_t* out_encrypted_keys
);

/**
 * @brief 二重暗号化された公開鍵リストを比較し、共通集合に対応する元の公開鍵を復元する。
 * @param original_keys 入力: 自分の元の公開鍵リスト P。(count_a * 33B)
 * @param my_double_set 入力: 戻ってきた二重暗号化リスト abP。(count_a * 33B)
 * @param remote_double_set 入力: 相手から受け取った二重暗号化リスト abQ。(count_b * 33B)
 * @param count_a 入力: 自分のリストの要素数。
 * @param count_b 入力: 相手のリストの要素数。
 * @param result_keys 出力: 共通集合に対応する元の公開鍵 P のリスト。(最大 count_a * 33B)
 * @param result_count 出力: 共通集合の要素数。
 * @return 成功した場合は1、失敗した場合は0。
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