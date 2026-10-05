#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISH_LOCK="$ROOT/ByeTunesLocal/iSH/ish.lock"
ALPINE_LOCK="$ROOT/ByeTunesLocal/iSH/alpine.lock"
OUT="${1:-$ROOT/.theos/ByeTunesISH.bundle}"
WORK="${RUNNER_TEMP:-$ROOT/.build}/byetunes-ish-rootfs"

ISH_REPO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$ISH_LOCK")"
ISH_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$ISH_LOCK")"
IMAGE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "$ALPINE_LOCK")"
EXPECTED_FFMPEG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["expectedFFmpeg"])' "$ALPINE_LOCK")"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

git clone --filter=blob:none "$ISH_REPO" "$WORK/ish"
git -C "$WORK/ish" checkout --detach "$ISH_COMMIT"
git -C "$WORK/ish" submodule update --init --recursive

CID="$(docker create --platform linux/386 "$IMAGE" /bin/sh -c 'while :; do sleep 3600; done')"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
docker start "$CID" >/dev/null
docker exec "$CID" /bin/sh -ec '
  apk add --no-cache busybox ca-certificates curl ffmpeg
  rm -rf /var/cache/apk/*
  mkdir -p /mnt/byetunes /tmp
  chmod 1777 /tmp
'
docker exec "$CID" apk info -vv > "$OUT/package-manifest.txt"
docker export "$CID" > "$WORK/docker-rootfs.tar"
mkdir -p "$WORK/rootfs-normalized"
tar -xf "$WORK/docker-rootfs.tar" -C "$WORK/rootfs-normalized"
tar --format=gnu --numeric-owner -C "$WORK/rootfs-normalized" -czf "$WORK/alpine-i386.tar.gz" .
docker rm -f "$CID" >/dev/null
trap - EXIT

meson setup "$WORK/ish-build" "$WORK/ish" --buildtype=release
ninja -C "$WORK/ish-build" tools/fakefsify
FAKEFSIFY="$WORK/ish-build/tools/fakefsify"
test -x "$FAKEFSIFY"

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
"$FAKEFSIFY" "$WORK/alpine-i386.tar.gz" "$OUT/rootfs"
test -d "$OUT/rootfs/data"
test -s "$OUT/rootfs/meta.db"
grep -Fq "ffmpeg-$EXPECTED_FFMPEG " "$OUT/package-manifest.txt"
grep -Eq '^curl-' "$OUT/package-manifest.txt"

cp "$WORK/ish/LICENSE.md" "$OUT/ISH-LICENSE.md"
cp "$WORK/ish/LICENSE.IOS" "$OUT/ISH-LICENSE.IOS"
cp "$ISH_LOCK" "$OUT/ish.lock"
cp "$ALPINE_LOCK" "$OUT/alpine.lock"

VERSION="ish-$ISH_COMMIT-alpine-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ALPINE_LOCK")"
printf '%s\n' "$VERSION" > "$OUT/rootfs.version"

python3 - "$OUT/provenance.json" "$ISH_COMMIT" "$IMAGE" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({
        "ishRepository":"https://github.com/ish-app/ish",
        "ishCommit":sys.argv[2],
        "alpineImage":sys.argv[3],
        "architecture":"i386",
        "packages":["busybox","ca-certificates","curl","ffmpeg"],
        "youtube":False,
        "purpose":"ByeTunesLocal Linux child-process compatibility"
    }, fh, indent=2, sort_keys=True)
PY

echo "Built official-iSH ByeTunes rootfs bundle at $OUT"
