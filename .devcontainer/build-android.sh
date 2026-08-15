#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_root="${repo_root}/android"
artifact_dir="${repo_root}/artifacts"
apk_source="${android_root}/app/build/outputs/apk/debug/app-debug.apk"
apk_target="${artifact_dir}/NetAccelerator-android-debug.apk"

gradle --project-dir "${android_root}" --no-daemon :app:assembleDebug
mkdir -p "${artifact_dir}"
cp "${apk_source}" "${apk_target}"

echo "APK: ${apk_target}"
sha256sum "${apk_target}"
