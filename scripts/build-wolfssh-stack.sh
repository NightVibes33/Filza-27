#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$PWD/Vendor/wolfssh}"
WOLFSSH_COMMIT="${WOLFSSH_COMMIT:-e7c8dc2c2c54e5f0f2986be592e2243725a4dd33}"
WOLFSSL_COMMIT="${WOLFSSL_COMMIT:-9ab8a4b19debdade06b10d30cf70167de8f9b915}"

# GitHub's macOS image includes autoconf but does not guarantee Automake's
# aclocal or GNU libtool. wolfSSL/wolfSSH master are source checkouts, so their
# configure scripts must be regenerated reproducibly before cross-compiling.
if ! command -v aclocal >/dev/null 2>&1 || ! command -v automake >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew is required to install automake" >&2; exit 2; }
  brew install automake
fi
if ! command -v glibtoolize >/dev/null 2>&1 && ! command -v libtoolize >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew is required to install GNU libtool" >&2; exit 2; }
  brew install libtool
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
AR="$(xcrun --sdk iphoneos --find ar)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
MIN_IOS="17.0"
WORK="$(mktemp -d /tmp/filza-wolfssh.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

COMMON_CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -fPIC -O2"
# Autoconf's CPU tuple must agree with clang -arch arm64. Using `arm-*` makes
# wolfSSL select its 32-bit ARM SP assembly even though clang emits arm64.
HOST="aarch64-apple-darwin"

printf 'Building wolfSSL %s for iOS arm64\n' "$WOLFSSL_COMMIT"
git clone --filter=blob:none https://github.com/wolfSSL/wolfssl.git "$WORK/wolfssl"
git -C "$WORK/wolfssl" checkout --detach "$WOLFSSL_COMMIT"
(
  cd "$WORK/wolfssl"
  autoreconf -fi
  env CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="$COMMON_CFLAGS" \
      ./configure \
        --host="$HOST" \
        --enable-static --disable-shared \
        --enable-wolfssh --enable-keygen \
        --disable-examples
  make -j"$JOBS" src/libwolfssl.la
)

test -s "$WORK/wolfssl/src/.libs/libwolfssl.a"
cp "$WORK/wolfssl/src/.libs/libwolfssl.a" "$PREFIX/lib/libwolfssl.a"
mkdir -p "$PREFIX/include/wolfssl"
cp -R "$WORK/wolfssl/wolfssl/." "$PREFIX/include/wolfssl/"

printf 'Building wolfSSH %s for iOS arm64\n' "$WOLFSSH_COMMIT"
git clone --filter=blob:none https://github.com/wolfSSL/wolfssh.git "$WORK/wolfssh"
git -C "$WORK/wolfssh" checkout --detach "$WOLFSSH_COMMIT"
(
  cd "$WORK/wolfssh"
  autoreconf -fi
  env CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="$COMMON_CFLAGS" \
      CPPFLAGS="-I$PREFIX/include" \
      LDFLAGS="-L$PREFIX/lib" \
      LIBS="-lwolfssl" \
      ./configure \
        --host="$HOST" \
        --enable-static --disable-shared \
        --enable-sftp --enable-scp \
        --disable-examples
  make -j"$JOBS" src/libwolfssh.la
)

test -s "$WORK/wolfssh/src/.libs/libwolfssh.a"
cp "$WORK/wolfssh/src/.libs/libwolfssh.a" "$PREFIX/lib/libwolfssh.a"
mkdir -p "$PREFIX/include/wolfssh"
cp -R "$WORK/wolfssh/wolfssh/." "$PREFIX/include/wolfssh/"

printf '%s\n' "$WOLFSSH_COMMIT" > "$PREFIX/WOLFSSH_COMMIT"
printf '%s\n' "$WOLFSSL_COMMIT" > "$PREFIX/WOLFSSL_COMMIT"

lipo -info "$PREFIX/lib/libwolfssh.a"
lipo -info "$PREFIX/lib/libwolfssl.a"
file "$PREFIX/lib/libwolfssh.a" "$PREFIX/lib/libwolfssl.a"
echo "wolfSSH iOS stack staged at $PREFIX"
