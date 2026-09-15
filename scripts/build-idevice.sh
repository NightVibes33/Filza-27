#!/bin/bash
set -euxo pipefail

IDEVICE_COMMIT="37ee77cf713f483551f3cf33ea8b2087a40058ca"
OUTPUT_ROOT="${1:-$PWD/Vendor/idevice}"
SOURCE_ROOT="${RUNNER_TEMP:-/tmp}/filzaslop-idevice-src"
TARGET_TRIPLE="aarch64-apple-ios"

rm -rf "$SOURCE_ROOT" "$OUTPUT_ROOT"
git clone --filter=blob:none https://github.com/jkcoxson/idevice.git "$SOURCE_ROOT"
git -C "$SOURCE_ROOT" checkout --detach "$IDEVICE_COMMIT"
test "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$IDEVICE_COMMIT"

rustc --version
cargo --version
rustup target add "$TARGET_TRIPLE"

export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$(xcrun --sdk iphoneos --find clang)"

cd "$SOURCE_ROOT"

# ByeTunes normally owns its process, so idevice's logger can safely install a
# global tracing subscriber. Embedded inside Filza it does not own the process;
# another subscriber may already exist. tracing_subscriber::init() panics in
# that case and aborts immediately when ContentView constructs DeviceManager.
# Keep the exact pinned idevice source but make global logger registration
# non-fatal for this embedded build. All transport APIs remain unchanged.
LOGGING_RS="$SOURCE_ROOT/ffi/src/logging.rs"
test -f "$LOGGING_RS"
python3 - "$LOGGING_RS" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = "        subscriber.init();"
new = "        let _ = subscriber.try_init();"
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one idevice logger init call, found {count}")
path.write_text(text.replace(old, new, 1))
PY
grep -Fq 'let _ = subscriber.try_init();' "$LOGGING_RS"
! grep -Fq 'subscriber.init();' "$LOGGING_RS"

# adapter_connect() returns ReadWriteOpaque*, while adapter_recv() expects the
# unrelated AdapterStreamHandle* wrapper. Never cast between those layouts.
# Export narrowly-scoped helpers for the exact ReadWriteOpaque that
# adapter_connect() gives Filza. These are used only by the Airlift experiment
# for standard RSD shim check-in plus the bounded StreamingZip/AirTraffic canary
# protocol. Reads/writes are capped and time-bounded so malformed service data
# cannot hang Filza indefinitely.
ADAPTER_RS="$SOURCE_ROOT/ffi/src/adapter.rs"
test -f "$ADAPTER_RS"
python3 - "$ADAPTER_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
markers = [
    'pub unsafe extern "C" fn idevice_stream_rsd_checkin(',
    'pub unsafe extern "C" fn idevice_stream_read_bounded(',
    'pub unsafe extern "C" fn idevice_stream_read_exact(',
    'pub unsafe extern "C" fn idevice_stream_write_all(',
]
for marker in markers:
    if marker in text:
        raise SystemExit(f"Airlift raw stream bridge already present unexpectedly: {marker}")

addition = r'''

/// Performs only the standard RSD shim check-in on the generic stream returned
/// by adapter_connect(), then restores the same socket to ReadWriteOpaque.
///
/// # Safety
/// `handle` must be a valid ReadWriteOpaque allocated by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_stream_rsd_checkin(
    handle: *mut ReadWriteOpaque,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let stream = unsafe { &mut *handle };
    let inner = match stream.inner.take() {
        Some(inner) => inner,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let (result, restored) = run_sync(async move {
        let mut device = idevice::Idevice::new(inner, "Filza-Airlift-RSD-Shim");
        let result = device.rsd_checkin().await;
        let restored = device.get_socket();
        (result, restored)
    });

    stream.inner = restored;

    match result {
        Ok(()) => null_mut(),
        Err(e) => {
            tracing::debug!("RSD shim check-in failed: {e}");
            ffi_err!(e)
        }
    }
}

/// Reads at most `max_length` bytes from ReadWriteOpaque, bounded to five
/// seconds. This remains useful for diagnostics where a short read is valid.
///
/// # Safety
/// `handle` must be valid; `data` must point to at least `max_length` writable
/// bytes; `length` must point to writable usize storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_stream_read_bounded(
    handle: *mut ReadWriteOpaque,
    data: *mut u8,
    length: *mut usize,
    max_length: usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || data.is_null() || length.is_null() || max_length == 0 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    if max_length > 65536 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let stream = unsafe { &mut *handle };
    let inner = match stream.inner.as_mut() {
        Some(inner) => inner,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let res: Result<Vec<u8>, std::io::Error> = run_sync(async move {
        let mut buf = vec![0u8; max_length];
        let count = match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            inner.read(&mut buf),
        )
        .await
        {
            Ok(read_result) => read_result?,
            Err(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "bounded ReadWriteOpaque read timed out",
                ));
            }
        };
        buf.truncate(count);
        Ok(buf)
    });

    match res {
        Ok(received_data) => {
            let received_len = received_data.len();
            unsafe {
                std::ptr::copy_nonoverlapping(received_data.as_ptr(), data, received_len);
                *length = received_len;
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Reads exactly `length` bytes from ReadWriteOpaque with an eight-second
/// deadline. Used for framed plist headers and payloads.
///
/// # Safety
/// `handle` must be valid and `data` must point to at least `length` writable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_stream_read_exact(
    handle: *mut ReadWriteOpaque,
    data: *mut u8,
    length: usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || data.is_null() || length == 0 || length > 4 * 1024 * 1024 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let stream = unsafe { &mut *handle };
    let inner = match stream.inner.as_mut() {
        Some(inner) => inner,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let res: Result<Vec<u8>, std::io::Error> = run_sync(async move {
        let mut buf = vec![0u8; length];
        match tokio::time::timeout(
            std::time::Duration::from_secs(8),
            inner.read_exact(&mut buf),
        )
        .await
        {
            Ok(read_result) => {
                read_result?;
                Ok(buf)
            }
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "exact ReadWriteOpaque read timed out",
            )),
        }
    });

    match res {
        Ok(received_data) => {
            unsafe {
                std::ptr::copy_nonoverlapping(received_data.as_ptr(), data, received_data.len());
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Writes the complete supplied buffer to ReadWriteOpaque with an eight-second
/// deadline. The caller owns all framing and is capped at four MiB per call.
///
/// # Safety
/// `handle` must be valid and `data` must point to at least `length` readable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_stream_write_all(
    handle: *mut ReadWriteOpaque,
    data: *const u8,
    length: usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || data.is_null() || length == 0 || length > 4 * 1024 * 1024 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let owned = unsafe { std::slice::from_raw_parts(data, length) }.to_vec();
    let stream = unsafe { &mut *handle };
    let inner = match stream.inner.as_mut() {
        Some(inner) => inner,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let res: Result<(), std::io::Error> = run_sync(async move {
        match tokio::time::timeout(
            std::time::Duration::from_secs(8),
            inner.write_all(&owned),
        )
        .await
        {
            Ok(write_result) => write_result,
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "ReadWriteOpaque write timed out",
            )),
        }
    });

    match res {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}
'''

path.write_text(text + addition)
PY
grep -Fq 'idevice_stream_rsd_checkin' "$ADAPTER_RS"
grep -Fq 'idevice_stream_read_bounded' "$ADAPTER_RS"
grep -Fq 'idevice_stream_read_exact' "$ADAPTER_RS"
grep -Fq 'idevice_stream_write_all' "$ADAPTER_RS"
grep -Fq 'ReadWriteOpaque write timed out' "$ADAPTER_RS"

# The complete ByeTunes DeviceManager uses substantially more than AFC: it
# opens heartbeat, lockdown/notification-proxy and RSD/CoreDevice paths too.
# Build idevice-ffi with its normal default feature set, matching ByeTunes'
# own successful unsigned-device workflow instead of the old reduced bridge's
# AFC-only feature subset.
cargo build \
  --manifest-path ffi/Cargo.toml \
  --release \
  --locked \
  --target "$TARGET_TRIPLE"

LIBRARY="$SOURCE_ROOT/target/$TARGET_TRIPLE/release/libidevice_ffi.a"
test -f "$LIBRARY"
mkdir -p "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/include"
cp "$LIBRARY" "$OUTPUT_ROOT/lib/libidevice_ffi.a"
cp "$SOURCE_ROOT/ffi/idevice.h" "$OUTPUT_ROOT/include/idevice.h"

grep -Fq 'idevice_stream_rsd_checkin' "$OUTPUT_ROOT/include/idevice.h"
grep -Fq 'idevice_stream_read_bounded' "$OUTPUT_ROOT/include/idevice.h"
grep -Fq 'idevice_stream_read_exact' "$OUTPUT_ROOT/include/idevice.h"
grep -Fq 'idevice_stream_write_all' "$OUTPUT_ROOT/include/idevice.h"
file "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/include/idevice.h"
shasum -a 256 "$OUTPUT_ROOT/lib/libidevice_ffi.a"
printf '%s\n' "$IDEVICE_COMMIT" > "$OUTPUT_ROOT/COMMIT"
