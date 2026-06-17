#!/usr/bin/env bash
# docker/install-tools.sh - download and SHA256-verify muster's runtime
# toolchain into /usr/local/bin during the image build.
#
# Every artifact is pinned to an exact version and checksum for both supported
# architectures. Verification is fail-closed: a missing or mismatched checksum
# aborts the build, so the published image can only ever contain the exact
# bytes recorded here. Bump a version and its two checksums together.
#
# Arch is taken from the build's TARGETARCH (set automatically by buildx):
# amd64 or arm64. No other architecture is accepted.
set -euo pipefail

K3D_VERSION="v5.8.3"
HELM_VERSION="v3.18.4"
KUBECTL_VERSION="v1.33.1"
NODE_VERSION="v24.14.0"
DOCKER_VERSION="27.5.1"
YARN_VERSION="1.22.22"
GOSU_VERSION="1.17"

declare -A SHA=(
  ["k3d_amd64"]="dbaa79a76ace7f4ca230a1ff41dc7d8a5036a8ad0309e9c54f9bf3836dbe853e"
  ["k3d_arm64"]="0b8110f2229631af7402fb828259330985918b08fefd38b7f1b788a1c8687216"
  ["helm_amd64"]="f8180838c23d7c7d797b208861fecb591d9ce1690d8704ed1e4cb8e2add966c1"
  ["helm_arm64"]="c0a45e67eef0c7416a8a8c9e9d5d2d30d70e4f4d3f7bea5de28241fffa8f3b89"
  ["kubectl_amd64"]="5de4e9f2266738fd112b721265a0c1cd7f4e5208b670f811861f699474a100a3"
  ["kubectl_arm64"]="d595d1a26b7444e0beb122e25750ee4524e74414bbde070b672b423139295ce6"
  ["node_amd64"]="41cd79bb7877c81605a9e68ec4c91547774f46a40c67a17e34d7179ef11729df"
  ["node_arm64"]="e7adfca03d9173276114a6f2219df1a7d25e1bfd6bbd771d3f839118a2053094"
  ["docker_amd64"]="4f798b3ee1e0140eab5bf30b0edc4e84f4cdb53255a429dc3bbae9524845d640"
  ["docker_arm64"]="e6b53725a73763ab3f988c73f8772eaed429754c1a579db5ff11f21990fd1817"
  ["gosu_amd64"]="bbc4136d03ab138b1ad66fa4fc051bafc6cc7ffae632b069a53657279a450de3"
  ["gosu_arm64"]="c3805a85d17f4454c23d7059bcb97e1ec1af272b90126e79ed002342de08389b"
)

# pinned_sha <tool> - the SHA256 for <tool> on the build's target arch. Keys
# use underscores (tool_arch) so the array index never contains a hyphen, which
# shfmt would otherwise misread as arithmetic.
pinned_sha() {
  printf '%s' "${SHA[${1}_${arch}]:-}"
}

arch="${TARGETARCH:?TARGETARCH must be set (amd64|arm64)}"
case "$arch" in
  amd64) node_arch="x64" docker_arch="x86_64" ;;
  arm64) node_arch="arm64" docker_arch="aarch64" ;;
  *)
    echo "unsupported TARGETARCH '$arch' (amd64|arm64)" >&2
    exit 1
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# fetch_verify <url> <dest> <expected-sha256>
fetch_verify() {
  local url="$1" dest="$2" want="$3" got
  [ -n "$want" ] || {
    echo "no pinned checksum for $dest" >&2
    exit 1
  }
  curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  got="$(sha256sum "$dest" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  actual   $got" >&2
    exit 1
  fi
  echo "verified $dest ($want)"
}

install -d /usr/local/bin

echo "==> k3d $K3D_VERSION ($arch)"
fetch_verify \
  "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${arch}" \
  k3d "$(pinned_sha k3d)"
install -m 0755 k3d /usr/local/bin/k3d

echo "==> helm $HELM_VERSION ($arch)"
fetch_verify \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
  helm.tgz "$(pinned_sha helm)"
tar -xzf helm.tgz "linux-${arch}/helm"
install -m 0755 "linux-${arch}/helm" /usr/local/bin/helm

echo "==> kubectl $KUBECTL_VERSION ($arch)"
fetch_verify \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
  kubectl "$(pinned_sha kubectl)"
install -m 0755 kubectl /usr/local/bin/kubectl

echo "==> docker CLI $DOCKER_VERSION ($arch)"
fetch_verify \
  "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz" \
  docker.tgz "$(pinned_sha docker)"
tar -xzf docker.tgz docker/docker
install -m 0755 docker/docker /usr/local/bin/docker

echo "==> gosu $GOSU_VERSION ($arch)"
fetch_verify \
  "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${arch}" \
  gosu "$(pinned_sha gosu)"
install -m 0755 gosu /usr/local/bin/gosu

echo "==> node $NODE_VERSION ($arch) + yarn $YARN_VERSION"
fetch_verify \
  "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${node_arch}.tar.xz" \
  node.tar.xz "$(pinned_sha node)"
mkdir -p /usr/local/lib/nodejs
tar -xJf node.tar.xz -C /usr/local/lib/nodejs --strip-components=1
ln -sf /usr/local/lib/nodejs/bin/node /usr/local/bin/node
ln -sf /usr/local/lib/nodejs/bin/npm /usr/local/bin/npm
ln -sf /usr/local/lib/nodejs/bin/npx /usr/local/bin/npx
# Yarn classic, pinned and fully materialized at build time so there is no
# first-run network fetch (unlike corepack, which downloads yarn on demand).
/usr/local/lib/nodejs/bin/npm install -g "yarn@${YARN_VERSION}"
ln -sf /usr/local/lib/nodejs/bin/yarn /usr/local/bin/yarn
ln -sf /usr/local/lib/nodejs/bin/yarnpkg /usr/local/bin/yarnpkg

echo "==> versions"
k3d version
helm version --short
kubectl version --client
docker --version
node --version
yarn --version
gosu --version
