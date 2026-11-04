#!/bin/bash
# Builds TabScreen.app in this folder (or where TABSCREEN_APP says). Everything printed is also saved to build.log.
set -eo pipefail
cd "$(dirname "$0")"
exec > >(tee build.log) 2>&1

echo "== Building TabScreen ($(date)) =="
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's command line developer tools are missing."
  echo "Run this in Terminal, let it finish, then build again:"
  echo "    xcode-select --install"
  exit 1
fi
sw_vers || true
xcrun swiftc --version || true

APP="${TABSCREEN_APP:-TabScreen.app}"
REBUILD=0
if [ -f "$APP/Contents/MacOS/TabScreen" ]; then REBUILD=1; fi

mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "-- Compiling the virtual display bridge"
xcrun clang -fobjc-arc -fmodules -arch arm64 -mmacosx-version-min=13.0 \
  -c Sources/TSVirtualDisplay.m -o build/TSVirtualDisplay.o

echo "-- Compiling the app"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -import-objc-header Sources/TSVirtualDisplay.h \
  Sources/*.swift build/TSVirtualDisplay.o \
  -o "$APP/Contents/MacOS/TabScreen"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/viewer.html "$APP/Contents/Resources/viewer.html"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# The tablet app (built separately, see Android/build-apk.sh). TabScreen installs it on the tablet over USB.
if [ -f Android/TabScreen.apk ]; then
  cp Android/TabScreen.apk "$APP/Contents/Resources/TabScreen.apk"
else
  rm -f "$APP/Contents/Resources/TabScreen.apk"
  echo "   Android/TabScreen.apk is missing: the tablet will use Chrome instead of the TabScreen app"
fi

echo "-- Signing"
# macOS ties privacy permissions (Screen Recording) to the app's signature. Signing every build with the same
# local certificate keeps the permission across rebuilds. The certificate is made once, stays on this Mac,
# and lives in its own small keychain, so the login keychain isn't touched.
SIGN_DIR="$HOME/Library/Application Support/TabScreen/Signing"
KEYCHAIN="$SIGN_DIR/TabScreen.keychain-db"
KEYCHAIN_PASSWORD="tabscreen-local-signing"   # only protects this local signing key
CERT_NAME="TabScreen Local Signing"

signing_identity() {
  security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1/ {print $NF; exit}' || true
}

create_signing_identity() {
  local tmp status=1
  tmp="$(mktemp -d)"
  printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' \
    '[dn]' "CN = $CERT_NAME" \
    '[ext]' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' \
    'extendedKeyUsage = critical, codeSigning' > "$tmp/cert.cnf"
  mkdir -p "$SIGN_DIR"
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
       -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT_NAME" \
       -passout "pass:$KEYCHAIN_PASSWORD" -out "$tmp/identity.p12" >/dev/null 2>&1 \
    && security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security set-keychain-settings "$KEYCHAIN" \
    && security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null \
    && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
  then
    status=0
  fi
  rm -rf "$tmp"
  return $status
}

SIGNED_WITH=""
if [ -f "$KEYCHAIN" ] && security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" 2>/dev/null; then
  SIGNED_WITH="$(signing_identity)"
fi
if [ -z "$SIGNED_WITH" ]; then
  if [ -f "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"; fi
  echo "   Creating TabScreen's own signing certificate (one time; it stays on this Mac)"
  if create_signing_identity; then
    SIGNED_WITH="$(signing_identity)"
  else
    echo "   Couldn't create it"
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
  fi
fi
if [ -n "$SIGNED_WITH" ] && codesign --force --keychain "$KEYCHAIN" --sign "$SIGNED_WITH" "$APP"; then
  echo "   Signed with TabScreen's own certificate, so Screen Recording stays allowed after rebuilds"
else
  SIGNED_WITH=""
  codesign --force --sign - "$APP"
  echo "   Signed without a certificate: macOS will ask for Screen Recording again after rebuilds"
fi

touch "$APP"   # nudges Finder to refresh the icon
mkdir -p "$SIGN_DIR"
PREVIOUS_SIGNATURE="$(cat "$SIGN_DIR/last-signature" 2>/dev/null || true)"
echo "${SIGNED_WITH:-none}" > "$SIGN_DIR/last-signature"
if [ "$REBUILD" = 1 ] && { [ -z "$SIGNED_WITH" ] || [ "$PREVIOUS_SIGNATURE" != "$SIGNED_WITH" ]; }; then
  # The signature changed, so macOS sees a new app: clear the old Screen Recording entry so macOS asks again
  # instead of showing a switch that looks on but no longer works.
  tccutil reset ScreenCapture local.tabscreen >/dev/null 2>&1 || true
  echo "   macOS will ask for Screen Recording permission once more"
fi
echo "== Build succeeded: $APP =="
