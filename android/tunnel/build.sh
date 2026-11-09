#!/bin/bash
# Builds the Phone Farm VPN client (a fork of the gnirehtet client, see README.md here) into
# Resources/gnirehtet/gnirehtet.apk. Run by hand after changing android/tunnel and commit the APK.
# Signs with ~/.android/phonefarm-tunnel.keystore (created on first use). A phone that has the APK
# signed by another key gets it reinstalled by Phone Farm.
set -euo pipefail

cd "$(dirname "$0")"
repo="$(cd ../.. && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
android_jar="$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | tail -1)"
tools="$(dirname "$(ls "$sdk"/build-tools/*/aapt2 | sort -V | tail -1)")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

"$tools/aapt2" compile --dir res -o "$out/res.zip"
"$tools/aapt2" link -o "$out/unsigned.apk" -I "$android_jar" --manifest AndroidManifest.xml \
    --rename-manifest-package local.phonefarm.tunnel --java "$out/gen" "$out/res.zip"
mkdir -p "$out/classes"
javac --release 8 -nowarn -classpath "$android_jar" -d "$out/classes" \
    $(find src "$out/gen" -name '*.java')
"$tools/d8" --release --min-api 21 --lib "$android_jar" --output "$out" $(find "$out/classes" -name '*.class')
(cd "$out" && zip -q unsigned.apk classes.dex)
"$tools/zipalign" -f -p 4 "$out/unsigned.apk" "$out/aligned.apk"

keystore="$HOME/.android/phonefarm-tunnel.keystore"
if [[ ! -f "$keystore" ]]; then
    mkdir -p "$(dirname "$keystore")"
    keytool -genkeypair -keystore "$keystore" -storepass phonefarm -keypass phonefarm -alias tunnel \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Phone Farm Tunnel" >/dev/null
fi
"$tools/apksigner" sign --v4-signing-enabled false --ks "$keystore" --ks-pass pass:phonefarm --ks-key-alias tunnel \
    --out "$repo/Resources/gnirehtet/gnirehtet.apk" "$out/aligned.apk"
"$tools/apksigner" verify "$repo/Resources/gnirehtet/gnirehtet.apk"
echo "Wrote Resources/gnirehtet/gnirehtet.apk"
