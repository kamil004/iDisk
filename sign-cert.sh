#!/bin/bash
# Tworzy i importuje trwały certyfikat podpisywania kodu iDisk (raz na maszynę).
# Stabilna tożsamość = stabilny CDHash signature → uprawnienie
# „Pełny dostęp do dysku” nie ginie przy kolejnych buildach i reinstalacjach.
# Użycie: ./sign-cert.sh (potem ./build-app.sh)
set -euo pipefail

IDENT="iDisk Code Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENT"; then
  echo "tożsamość „$IDENT” już istnieje — nic nie robię."
  exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Certyfikat musi mieć: keyUsage=critical,digitalSignature + EKU codeSigning
# (jak „HideIcon Dev”/„IconSpace Dev”). Bez keyUsage:
#   codesign → „Invalid Key Usage for policy” (identyfikator nieakceptowany),
# bez EKU:  find-identity -p codesigning pomija tożsamość.
openssl req -x509 -newkey rsa:2048 -keyout "$T/idisk.key" -out "$T/idisk.crt" \
  -days 7300 -nodes -subj "/CN=$IDENT" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

# OpenSSL 3 wymaga -legacy, inaczej security nie odczyta p12
openssl pkcs12 -export -legacy -out "$T/idisk.p12" -inkey "$T/idisk.key" -in "$T/idisk.crt" \
  -passout pass:idisk >/dev/null 2>&1

security import "$T/idisk.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" -P idisk -T /usr/bin/codesign -T /usr/bin/security -A

# Identyfikator musi być ZAUFANY dla podpisywania kodu:
# without this → „CSSMERR_TP_NOT_TRUSTED”, wypada z „valid identities”.
security add-trusted-cert -r trustRoot -p codeSign "$T/idisk.crt"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENT"; then
  echo "utworzono i zaimportowano tożsamość „$IDENT” (ważność 20 lat, trustRoot dla codeSign)."
else
  echo "BŁĄD: tożsamość nie pojawiła się w find-identity — sprawdź kluczownice." >&2
  exit 1
fi