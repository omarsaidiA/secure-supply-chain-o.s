#!/usr/bin/env bash
# Verify an image the way a consumer (or a deployment gate) should before running it.
#
#   scripts/verify.sh ghcr.io/owner/repo@sha256:... owner/repo
#
# Requires cosign, gh (authenticated), jq, docker and curl.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 IMAGE@sha256:DIGEST OWNER/REPO" >&2
  exit 2
fi
ref=$1
repo=$2
# Only a signature made by this workflow, on the main branch, is accepted
identity="https://github.com/${repo}/.github/workflows/supply-chain.yml@refs/heads/main"
issuer="https://token.actions.githubusercontent.com"

step() { printf '\n==> %s\n' "$*"; }

step "Reference is pinned by digest"
if [[ "$ref" != *@sha256:* ]]; then
  echo "refusing '$ref': verify a digest, a tag can point to other content tomorrow" >&2
  exit 1
fi
echo "$ref"

step "Signature (Sigstore keyless, identity: $identity)"
cosign verify "$ref" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
  -o text | sed -n '/checks were performed/,$p'

step "SBOM attestation (SPDX), signed by the same identity"
packages=$(cosign verify-attestation "$ref" --type spdxjson \
  --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" 2>/dev/null \
  | jq -rs '.[0].payload | @base64d | fromjson | .predicate.packages | length')
echo "signed SBOM lists $packages packages"

step "SLSA build provenance (GitHub attestation)"
built_from=$(gh attestation verify "oci://$ref" --repo "$repo" \
  --signer-workflow "$repo/.github/workflows/supply-chain.yml" --format json \
  | jq -r '.[0].verificationResult.statement.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit')
echo "provenance: built from commit $built_from"

step "The binary reports the same commit as the signed provenance"
container=$(docker run -d --rm -p 127.0.0.1:18080:8080 --read-only --cap-drop ALL "$ref")
trap 'docker stop "$container" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do
  reported=$(curl -fs http://127.0.0.1:18080/version | jq -r .commit) && break
  sleep 1
done
echo "binary: built from commit ${reported:-?}"
if [ "${reported:-}" != "$built_from" ]; then
  echo "mismatch between the running binary and its provenance" >&2
  exit 1
fi

printf '\nVerified: signed by %s, with a signed SBOM and SLSA provenance.\n' "$identity"
