#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
task_identity_dir=local/display-identity
if [ -e "$task_identity_dir" ]; then
    printf '%s\n' 'Identity folder already exists; no keys replaced.'
    exit 1
fi
test -x /usr/bin/openssl
umask 077
mkdir "$task_identity_dir"
/usr/bin/openssl rand -hex 32 > "$task_identity_dir/password.txt"
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -subj '/CN=METZ Display Mac' -keyout "$task_identity_dir/private.key" \
    -out "$task_identity_dir/certificate.pem" 2> "$task_identity_dir/generation.log"
/usr/bin/openssl pkcs12 -export -inkey "$task_identity_dir/private.key" \
    -in "$task_identity_dir/certificate.pem" -out "$task_identity_dir/identity.p12" \
    -passout "file:$task_identity_dir/password.txt"
printf '%s\n' 'Created private local/display-identity. Select this folder in METZ Display.'
