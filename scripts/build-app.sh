#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
# PHONE_FARM_UNIVERSAL=1 builds one binary for both Apple Silicon and Intel Macs (used by CI).
build_args=(-c release)
if [[ "${PHONE_FARM_UNIVERSAL:-}" == "1" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"

app="$PWD/.build/Phone Farm.app"
reader_dir="$PWD/.build/keyboard-reader"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
android_jar=""
d8=""
for jar in "$sdk"/platforms/android-*/android.jar; do
    if [[ -f "$jar" ]]; then android_jar="$jar"; fi
done
for tool in "$sdk"/build-tools/*/d8; do
    if [[ -x "$tool" ]]; then d8="$tool"; fi
done
if [[ -z "$android_jar" || -z "$d8" ]] || ! command -v javac >/dev/null; then
    printf '%s\n' "Cần JDK và Android SDK có Platform cùng Build Tools (d8) để build Phone Farm." >&2
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$reader_dir"
javac --release 8 -classpath "$android_jar" -d "$reader_dir" android/*.java
"$d8" --min-api 24 --lib "$android_jar" --output "$reader_dir" \
    "$reader_dir"/AccessibilitySession*.class "$reader_dir"/KeyboardReader*.class "$reader_dir"/ThreadsReader*.class \
    "$reader_dir"/ProxyRelay*.class "$reader_dir"/ProxyCheck.class "$reader_dir"/KeyboardTyper*.class
cp "$reader_dir/classes.dex" "$app/Contents/Resources/KeyboardReader.dex"
# Replace the executable with a new file so a running Phone Farm keeps its old binary intact.
cp "$binary_dir/PhoneFarm" "$app/Contents/MacOS/PhoneFarm.new"
mv -f "$app/Contents/MacOS/PhoneFarm.new" "$app/Contents/MacOS/PhoneFarm"
cp scripts/Info.plist "$app/Contents/Info.plist"
# CI passes the release version and build number; local builds keep the values in Info.plist.
if [[ -n "${PHONE_FARM_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PHONE_FARM_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${PHONE_FARM_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PHONE_FARM_BUILD" "$app/Contents/Info.plist"
fi
ditto Resources/ThreadsDefaults "$app/Contents/Resources/ThreadsDefaults"
if [[ -f Resources/ai-key.enc.json ]]; then
    cp Resources/ai-key.enc.json "$app/Contents/Resources/ai-key.enc.json"
else
    rm -f "$app/Contents/Resources/ai-key.enc.json"
    printf '%s\n' "Chưa có Resources/ai-key.enc.json; app sẽ không có khóa AI." >&2
fi
# Sign with a stable identity so macOS Keychain keeps trusting the app across rebuilds.
# Ad hoc signatures change on every build and lose access to the saved AI key.
identity="${PHONE_FARM_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" --identifier local.phonefarm.mac "$app"
else
    printf '%s\n' "Không có chứng chỉ ký ổn định; ký ad hoc. Sau mỗi lần build có thể phải cài lại khóa AI." >&2
    codesign --force --sign - "$app"
fi
printf '\n%s\n' "$app"
