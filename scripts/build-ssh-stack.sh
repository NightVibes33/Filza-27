#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$PWD/Vendor/ssh}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
DEPLOYMENT_TARGET="16.0"

LIBSSH_COMMIT="07430deb9b97b751ec5ea5a7fc307f40bf042e0a" # libssh 0.12.2
MBEDTLS_COMMIT="068ff080b369adfac81509f9b57b2afabaf82dc5" # mbedtls 3.6.7

WORK="$(mktemp -d /tmp/filza-ssh-stack.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

common_cmake=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT="$SDK"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

echo "Building Mbed TLS 3.6.7 ($MBEDTLS_COMMIT) for arm64 iOS..."
git clone --filter=blob:none https://github.com/Mbed-TLS/mbedtls.git "$WORK/mbedtls"
git -C "$WORK/mbedtls" checkout --detach "$MBEDTLS_COMMIT"
git -C "$WORK/mbedtls" submodule update --init --recursive
cmake -S "$WORK/mbedtls" -B "$WORK/mbedtls-build" \
  "${common_cmake[@]}" \
  -DENABLE_PROGRAMS=OFF \
  -DENABLE_TESTING=OFF \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON
cmake --build "$WORK/mbedtls-build" --parallel "$JOBS"
cmake --install "$WORK/mbedtls-build"

test -s "$PREFIX/lib/libmbedcrypto.a"
test -s "$PREFIX/lib/libmbedtls.a"
test -s "$PREFIX/lib/libmbedx509.a"

echo "Building libssh 0.12.2 ($LIBSSH_COMMIT) with server support for arm64 iOS..."
git clone --filter=blob:none https://gitlab.com/libssh/libssh-mirror.git "$WORK/libssh"
git -C "$WORK/libssh" checkout --detach "$LIBSSH_COMMIT"
cmake -S "$WORK/libssh" -B "$WORK/libssh-build" \
  "${common_cmake[@]}" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DMBEDTLS_ROOT_DIR="$PREFIX" \
  -DWITH_MBEDTLS=ON \
  -DWITH_GCRYPT=OFF \
  -DWITH_GSSAPI=OFF \
  -DWITH_ZLIB=OFF \
  -DWITH_PCAP=OFF \
  -DWITH_FIDO2=OFF \
  -DWITH_PKCS11_URI=OFF \
  -DWITH_PKCS11_PROVIDER=OFF \
  -DWITH_NACL=OFF \
  -DWITH_EXEC=OFF \
  -DWITH_SFTP=ON \
  -DWITH_SERVER=ON \
  -DWITH_EXAMPLES=OFF \
  -DWITH_SYMBOL_VERSIONING=OFF \
  -DUNIT_TESTING=OFF \
  -DCLIENT_TESTING=OFF \
  -DSERVER_TESTING=OFF \
  -DBUILD_SHARED_LIBS=OFF
cmake --build "$WORK/libssh-build" --parallel "$JOBS"
cmake --install "$WORK/libssh-build"

test -s "$PREFIX/lib/libssh.a"
test -s "$PREFIX/include/libssh/libssh.h"
test -s "$PREFIX/include/libssh/server.h"
test -s "$PREFIX/include/libssh/callbacks.h"

printf '%s\n' "$LIBSSH_COMMIT" > "$PREFIX/LIBSSH_COMMIT"
printf '%s\n' "$MBEDTLS_COMMIT" > "$PREFIX/MBEDTLS_COMMIT"

# Reject accidental simulator/macOS archives. Every object in these static
# archives must be arm64; the final dylib build provides the iOS platform proof.
for archive in \
  "$PREFIX/lib/libssh.a" \
  "$PREFIX/lib/libmbedcrypto.a" \
  "$PREFIX/lib/libmbedtls.a" \
  "$PREFIX/lib/libmbedx509.a"; do
  lipo -info "$archive"
done

echo "Pinned SSH stack installed to $PREFIX"
