#!/bin/bash
# rustpush embeds FairPlay certificates from rustpush/certs/fairplay, which isn't in git. Fill it
# with copies of the committed legacy certificate so the Rust code compiles.
set -euo pipefail

certs="$(dirname "$0")/../rustpush/certs"
mkdir -p "$certs/fairplay"
for name in $(grep -o 'include_cert!("[0-9]*")' "$certs/../src/activation.rs" | grep -o '[0-9]\+'); do
    [ -e "$certs/fairplay/$name.pem" ] || cp "$certs/legacy-fairplay/fairplay.pem" "$certs/fairplay/$name.pem"
    [ -e "$certs/fairplay/$name.crt" ] || cp "$certs/legacy-fairplay/fairplay.crt" "$certs/fairplay/$name.crt"
done
