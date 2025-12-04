cmake_minimum_required(VERSION 3.10)

project(psiring_auth C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(
        psiring_auth
        SHARED
        key_derivation.c
        psi.c
        ring_signature.c
)

# include/ 内のヘッダー (psi.h, key_derivation.h, ring_signature.h)
target_include_directories(
        psiring_auth
        PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# ============================
# Android 専用設定
# ============================
if(ANDROID)
    message(STATUS "Building for Android (${ANDROID_ABI})")

    # Android log (logcat) ライブラリ
    find_library(log-lib log)
    target_link_libraries(psiring_auth ${log-lib})

    # BoringSSL の libcrypto を ABI ごとにリンク
    set(CRYPTO_PATH
            "${CMAKE_CURRENT_SOURCE_DIR}/../../android/app/src/main/jniLibs/${ANDROID_ABI}/libcrypto.so"
    )

    if (EXISTS "${CRYPTO_PATH}")
        message(STATUS "Using bundled BoringSSL: ${CRYPTO_PATH}")
        target_link_libraries(psiring_auth ${CRYPTO_PATH})
    else()
        message(FATAL_ERROR "libcrypto.so not found: ${CRYPTO_PATH}")
    endif()

else()

    # ============================
    # Android 以外のプラットフォーム
    # ============================

    message(STATUS "Non-Android platform build")

    # 必要であればシステム OpenSSL を使用
    find_package(OpenSSL REQUIRED)

    if(OPENSSL_FOUND)
        message(STATUS "Using system OpenSSL: ${OPENSSL_CRYPTO_LIBRARY}")
        target_link_libraries(psiring_auth OpenSSL::Crypto)
    else()
        message(WARNING "OpenSSL not found — continuing without explicit link")
    endif()

endif()
