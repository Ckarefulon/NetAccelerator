#!/usr/bin/env bash
set -euo pipefail

java -version
gradle --version
sdkmanager --version

test -d "${ANDROID_SDK_ROOT}/platforms/android-35"
test -d "${ANDROID_SDK_ROOT}/build-tools/35.0.0"

echo "Android 构建环境已就绪。按 Ctrl+Shift+B 生成 APK。"
