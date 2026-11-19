#!/bin/bash
set -euo pipefail
umask 077

keychain="$RUNNER_TEMP/release-signing.keychain-db"
certificate="$RUNNER_TEMP/release-signing.p12"
trap 'rm -f "$certificate"' EXIT
keychain_password=$(openssl rand -hex 32)
printf '%s' "$SIGNING_CERTIFICATE" | base64 --decode > "$certificate"
escape_security_argument() {
    local escaped=${1//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    printf '%s' "$escaped"
}
{
    printf 'create-keychain -p "%s" "%s"\n' "$keychain_password" "$keychain"
    printf 'set-keychain-settings -lut 21600 "%s"\n' "$keychain"
    printf 'unlock-keychain -p "%s" "%s"\n' "$keychain_password" "$keychain"
    printf 'import "%s" -k "%s" -P "%s" -T /usr/bin/codesign -T /usr/bin/pkgbuild\n' \
        "$certificate" "$keychain" "$(escape_security_argument "$SIGNING_CERTIFICATE_PASSWORD")"
    printf 'set-key-partition-list -S apple-tool:,apple: -s -k "%s" "%s"\n' "$keychain_password" "$keychain"
} | security -qi > /dev/null 2>&1
security find-identity -v -p codesigning "$keychain" | grep -q 'Developer ID Application:'
security list-keychains -d user -s "$keychain"

export RELEASE_SIGNING_KEYCHAIN="$keychain"
expect <<'EXPECT'
set timeout 90
log_user 0
spawn xcrun notarytool store-credentials notary-profile --apple-id $env(APPLE_ID) --team-id $env(APPLE_TEAM_ID) --keychain $env(RELEASE_SIGNING_KEYCHAIN)
expect {
    -nocase -re {password[^\r\n]*:} { send -- "$env(NOTARY_PASSWORD)\r" }
    timeout { puts stderr "Notarytool password prompt timed out"; exit 1 }
    eof { puts stderr "Notarytool exited before prompting for credentials"; exit 1 }
}
expect {
    eof { exit [lindex [wait] 3] }
    timeout { puts stderr "Notarytool credential validation timed out"; exit 1 }
}
EXPECT
printf 'RELEASE_SIGNING_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"
