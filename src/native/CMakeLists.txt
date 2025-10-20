cmake_minimum_required(VERSION 3.10)

project(psiring_auth C) # プロジェクト名を psiring_auth に変更

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(
        psiring_auth
        SHARED
        key_derivation.c
        psi.c
        ring_signature.c
)

# OpenSSLのヘッダー（BoringSSLから取得）
target_include_directories(
        psiring_auth
        PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# Androidのログ出力ライブラリを探す
find_library(
        log-lib     # この変数にライブラリのパスが格納される
        log         # 探すライブラリの名前 (liblog.so)
)

# 明示的に libcrypto.so を ABIごとにリンク
set(CRYPTO_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../android/app/src/main/jniLibs/${ANDROID_ABI}/libcrypto.so")

target_link_libraries(
        psiring_auth
        ${log-lib}   # ★ log-lib をリンク対象に追加
        ${CRYPTO_LIB_PATH}
)
