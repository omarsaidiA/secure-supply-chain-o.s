#!/usr/bin/env bash
# Negative tests: verification must FAIL in each of these situations, otherwise it proves nothing.
#
#   scripts/tamper-test.sh ghcr.io/owner/repo@sha256:... owner/repo
#
# Requires cosign and docker.
set -euo pipefail

ref=$1
repo=$2
identity="https://github.com/${repo}/.github/workflows/supply-chain.yml@refs/heads/main"
issuer="https://token.actions.githubusercontent.com"
failures=0

# expect_rejected DESCRIPTION EXPECTED_REASON cosign-verify-arguments...
# The reason is checked too: a network error would also "fail" without proving anything.
expect_rejected() {
  local description=$1 reason=$2 out
  shift 2
  if out=$(cosign verify "$@" 2>&1); then
    echo "  FAIL  $description: verification unexpectedly succeeded"
    failures=$((failures + 1))
  elif grep -qF -- "$reason" <<<"$out"; then
    echo "  PASS  $description: rejected ($reason)"
  else
    echo "  FAIL  $description: rejected for another reason: $(tail -n 1 <<<"$out")"
    failures=$((failures + 1))
  fi
}
wrong_signer="none of the expected identities matched"
unsigned="no signatures found"

echo "1. Right image, wrong expected signer"
# A signature from any other workflow (or another repository) must not be accepted
expect_rejected "signed by .github/workflows/other.yml" "$wrong_signer" "$ref" \
  --certificate-identity "https://github.com/${repo}/.github/workflows/other.yml@refs/heads/main" \
  --certificate-oidc-issuer "$issuer"
expect_rejected "signed on another branch" "$wrong_signer" "$ref" \
  --certificate-identity "https://github.com/${repo}/.github/workflows/supply-chain.yml@refs/heads/dev" \
  --certificate-oidc-issuer "$issuer"

echo "2. A genuinely signed image, but by someone else"
# The distroless base image is signed by Google: valid for Google's identity, not for ours
base=gcr.io/distroless/static-debian13:nonroot
if cosign verify "$base" --certificate-identity keyless@distroless.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com >/dev/null 2>&1; then
  echo "  PASS  the base image's own signature (Google) is valid"
else
  echo "  FAIL  could not verify the base image with Google's identity"
  failures=$((failures + 1))
fi
expect_rejected "base image checked against this project's identity" "$wrong_signer" "$base" \
  --certificate-identity "$identity" --certificate-oidc-issuer "$issuer"

echo "3. Tampered image: one extra layer on top of the signed image"
# Throwaway local registry, so no tampered image is ever published
registry=$(docker run -d --rm -p 127.0.0.1:5000:5000 \
  registry:3@sha256:38907510915c3f1604c7e83d6ab602ab3020d092f73bdaed8696773693ff768c)
trap 'docker stop "$registry" >/dev/null 2>&1 || true' EXIT
workdir=$(mktemp -d)
echo "backdoor" > "$workdir/payload"
printf 'FROM %s\nCOPY payload /payload\n' "$ref" > "$workdir/Dockerfile"
for _ in $(seq 1 20); do curl -fs http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 1; done
docker build -q -t localhost:5000/tampered:1 "$workdir" >/dev/null
docker push -q localhost:5000/tampered:1 >/dev/null
expect_rejected "image with an added layer" "$unsigned" localhost:5000/tampered:1 --allow-http-registry \
  --certificate-identity "$identity" --certificate-oidc-issuer "$issuer"

if [ "$failures" -ne 0 ]; then
  echo "$failures negative test(s) failed"
  exit 1
fi
echo "All tampering attempts were detected."
