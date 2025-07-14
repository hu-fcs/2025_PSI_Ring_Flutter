#include "key_derivation.h"
#include <string.h>
#include <openssl/hkdf.h>
#include <openssl/evp.h>
#include <openssl/ecdsa.h>
#include <openssl/nid.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/rand.h>

#define HASH_LEN 32
#define SLOT_MS 600000  // 10分

int generate_master_key(uint8_t* out_master_key_32b) {
    return RAND_bytes(out_master_key_32b, HASH_LEN);
}

int derive_keypair_from_timestamp(
        const uint8_t* master_key,
        uint64_t timestamp_ms,
        uint8_t* out_priv_key_32b,
        uint8_t* out_pub_key_65b
) {
    uint64_t slot_time = (timestamp_ms / SLOT_MS) * SLOT_MS;

    // タイムスロットを8バイトのsaltに変換
    uint8_t salt[8];
    for (int i = 0; i < 8; i++) {
        salt[7 - i] = (slot_time >> (8 * i)) & 0xFF;
    }

    const char* info = "ecdsakey";

    uint8_t derived_priv[HASH_LEN];
    if (!HKDF(derived_priv, HASH_LEN, EVP_sha256(),
              master_key, HASH_LEN,
              salt, sizeof(salt),
              (const uint8_t*)info, strlen(info))) {
        return 0;
    }

    // EC鍵生成（secp256r1）
    EC_GROUP* group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    if (!group) return 0;

    EC_KEY* ec_key = EC_KEY_new();
    EC_KEY_set_group(ec_key, group);

    BIGNUM* priv_bn = BN_bin2bn(derived_priv, HASH_LEN, NULL);
    if (!priv_bn) {
        EC_KEY_free(ec_key);
        EC_GROUP_free(group);
        return 0;
    }

    EC_KEY_set_private_key(ec_key, priv_bn);

    EC_POINT* pub_point = EC_POINT_new(group);
    if (!EC_POINT_mul(group, pub_point, priv_bn, NULL, NULL, NULL)) {
        EC_KEY_free(ec_key);
        EC_GROUP_free(group);
        BN_free(priv_bn);
        return 0;
    }

    EC_KEY_set_public_key(ec_key, pub_point);

    // 出力
    BN_bn2binpad(priv_bn, out_priv_key_32b, 32);
    EC_POINT_point2oct(group, pub_point, POINT_CONVERSION_UNCOMPRESSED,
                       out_pub_key_65b, 65, NULL);

    EC_KEY_free(ec_key);
    EC_GROUP_free(group);
    EC_POINT_free(pub_point);
    BN_free(priv_bn);
    return 1;
}
