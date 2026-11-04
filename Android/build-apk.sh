#!/bin/bash
# Builds TabScreen.apk (the tablet app) without Android Studio or Gradle.
# Runs on Linux with Debian/Ubuntu's Android packages:
#   sudo apt-get install aapt apksigner zipalign dalvik-exchange android-sdk-platform-23 openjdk-17-jdk-headless
# The app is compiled against Android 6's API list and uses newer features (Android 11+) through reflection.
set -euo pipefail
cd "$(dirname "$0")"

SDK=/usr/lib/android-sdk
ANDROID_JAR="$SDK/platforms/android-23/android.jar"
DX="$SDK/build-tools/debian/dx"
KEYSTORE="signing/tabscreen-app.p12"
KEYSTORE_PASSWORD="tabscreen-local"   # local signing key; it only has to stay the same so updates install over the old app

rm -rf out
mkdir -p out/gen out/classes out/dex

echo "-- Resources"
aapt package -f -m -J out/gen -M AndroidManifest.xml -S res -I "$ANDROID_JAR" -0 arsc -F out/resources.apk

echo "-- Java"
javac -nowarn -Xlint:-options -source 8 -target 8 -encoding UTF-8 \
  -bootclasspath "$ANDROID_JAR" -classpath "$ANDROID_JAR" \
  -d out/classes $(find src out/gen -name '*.java')

echo "-- Dex"
"$DX" --dex --min-sdk-version=26 --output=out/dex/classes.dex out/classes

echo "-- Package"
cp out/resources.apk out/unaligned.apk
(cd out/dex && zip -q -X ../unaligned.apk classes.dex)
zipalign -f -p 4 out/unaligned.apk out/aligned.apk

if [ ! -f "$KEYSTORE" ]; then
  echo "-- Creating the app signing key (one time)"
  mkdir -p signing
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -storepass "$KEYSTORE_PASSWORD" \
    -alias tabscreen -keyalg EC -groupname secp256r1 -validity 10950 -dname "CN=TabScreen local build" >/dev/null
fi
apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KEYSTORE_PASSWORD" --ks-key-alias tabscreen \
  --min-sdk-version 26 --out TabScreen.apk out/aligned.apk
apksigner verify --min-sdk-version 26 TabScreen.apk
echo "== Built TabScreen.apk ($(stat -c %s TabScreen.apk) bytes) =="
