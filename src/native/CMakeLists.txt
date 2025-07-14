cmake_minimum_required(VERSION 3.10)

project(key_derivation C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(
        psiring_auth # ライブラリ名は適宜変更してください
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

# Androidログ用ライブラリ
find_library(log-lib log)

# 明示的に libcrypto.so を ABIごとにリンク
set(CRYPTO_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../android/app/src/main/jniLibs/${ANDROID_ABI}/libcrypto.so")

target_link_libraries(
        psiring_auth
        ${log-lib}
        ${CRYPTO_LIB_PATH}
)