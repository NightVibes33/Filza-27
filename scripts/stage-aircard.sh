#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/AirCard"
PIN="5026bf323df4f81a1b45cd107a68da164a7fd299"
rm -rf "$DEST"
git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$DEST"
git -C "$DEST" checkout --detach "$PIN"
test "$(git -C "$DEST" rev-parse HEAD)" = "$PIN"
rm -f "$DEST/ios-app/AirCardApp.swift"
printf '%s\n' "$PIN" > "$DEST/PINNED_REVISION"

# Swift emits one module for the Filza tweak; avoid basename collision with ByeTunes ContentView.swift.
mv "$DEST/ios-app/ContentView.swift" "$DEST/ios-app/AirCardContentView.swift"


# FILZA_AIRCARD_FS_FFI: expose AirCard's existing paired AFC transport to Filza.
cat >> "$DEST/rust-core/src/exploit.rs" <<'EOF'

// ---- Filza embedded AFC browser bridge --------------------------------------
pub unsafe fn filza_fs_list(
    pairing_path: *const c_char,
    remote_path: *const c_char,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "aircard_pairing.plist");
    let mut remote_path = opt_str(remote_path, "");
    if remote_path == "/" { remote_path.clear(); }
    let logger = Logger { cb: None, ctx: std::ptr::null_mut() };

    let result = idevice_ffi::run_sync_local(async move {
        let pairing_bytes = std::fs::read(&pairing_path)
            .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
        let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;
        let mut afc = tunnel.connect_afc(&logger).await?;
        let items = afc.list_dir(&remote_path).await
            .map_err(|e| format!("AFC list_dir('{remote_path}') failed: {e:?}"))?;

        let mut rows = Vec::new();
        for name in items {
            if name == "." || name == ".." { continue; }
            let full = if remote_path.is_empty() {
                name.clone()
            } else {
                format!("{}/{}", remote_path.trim_end_matches('/'), name)
            };
            let info = afc.get_file_info(&full).await.ok();
            let (kind, size, modified) = match info {
                Some(ref i) => (
                    i.st_ifmt.clone(),
                    i.size as u64,
                    i.modified.and_utc().timestamp(),
                ),
                None => ("unknown".to_string(), 0, 0),
            };
            rows.push(serde_json::json!({
                "name": name,
                "path": full,
                "kind": kind,
                "size": size,
                "modified": modified,
            }));
        }
        serde_json::to_string(&rows).map_err(|e| e.to_string())
    });

    match result {
        Ok(json) => {
            if !out_json.is_null() { *out_json = cstr(json); }
            0
        }
        Err(e) => {
            if !out_error.is_null() { *out_error = cstr(e); }
            1
        }
    }
}

pub unsafe fn filza_fs_read(
    pairing_path: *const c_char,
    remote_path: *const c_char,
    out_data: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_data.is_null() || out_len.is_null() { return 2; }
    *out_data = std::ptr::null_mut();
    *out_len = 0;

    let pairing_path = opt_str(pairing_path, "aircard_pairing.plist");
    let remote_path = opt_str(remote_path, "");
    if remote_path.is_empty() {
        if !out_error.is_null() { *out_error = cstr("remote_path must not be empty"); }
        return 1;
    }
    let logger = Logger { cb: None, ctx: std::ptr::null_mut() };

    let result = idevice_ffi::run_sync_local(async move {
        let pairing_bytes = std::fs::read(&pairing_path)
            .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
        let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;
        let mut afc = tunnel.connect_afc(&logger).await?;
        let mut fd = afc.open(&remote_path, AfcFopenMode::RdOnly).await
            .map_err(|e| format!("AFC open('{remote_path}') failed: {e:?}"))?;
        let data = fd.read_entire().await
            .map_err(|e| format!("AFC read('{remote_path}') failed: {e:?}"))?;
        let _ = fd.close().await;
        Ok::<Vec<u8>, String>(data)
    });

    match result {
        Ok(data) => {
            let boxed = data.into_boxed_slice();
            let len = boxed.len();
            let ptr = Box::into_raw(boxed) as *mut u8;
            *out_data = ptr;
            *out_len = len;
            0
        }
        Err(e) => {
            if !out_error.is_null() { *out_error = cstr(e); }
            1
        }
    }
}

pub unsafe fn filza_fs_bytes_free(data: *mut u8, len: usize) {
    if data.is_null() { return; }
    let slice = std::ptr::slice_from_raw_parts_mut(data, len);
    let _ = Box::from_raw(slice);
}
EOF

cat >> "$DEST/rust-core/src/lib.rs" <<'EOF'

// Filza embedded filesystem bridge. These use AirCard's normal paired AFC
// transport over the same RSD/Lockdown tunnel selected by the Airlift core.
#[no_mangle]
pub unsafe extern "C" fn al_filza_fs_list(
    pairing_path: *const c_char,
    remote_path: *const c_char,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    exploit::filza_fs_list(pairing_path, remote_path, out_json, out_error)
}

#[no_mangle]
pub unsafe extern "C" fn al_filza_fs_read(
    pairing_path: *const c_char,
    remote_path: *const c_char,
    out_data: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut *mut c_char,
) -> i32 {
    exploit::filza_fs_read(pairing_path, remote_path, out_data, out_len, out_error)
}

#[no_mangle]
pub unsafe extern "C" fn al_filza_fs_bytes_free(data: *mut u8, len: usize) {
    exploit::filza_fs_bytes_free(data, len)
}
EOF

cat >> "$DEST/rust-core/include/airlift.h" <<'EOF'

// Filza embedded paired-AFC filesystem bridge.
// Returned JSON/string buffers use al_string_free(); byte buffers use
// al_filza_fs_bytes_free().
int32_t al_filza_fs_list(const char *pairing_path,
                         const char *remote_path,
                         char **out_json,
                         char **out_error);
int32_t al_filza_fs_read(const char *pairing_path,
                         const char *remote_path,
                         uint8_t **out_data,
                         size_t *out_len,
                         char **out_error);
void al_filza_fs_bytes_free(uint8_t *data, size_t len);
EOF
