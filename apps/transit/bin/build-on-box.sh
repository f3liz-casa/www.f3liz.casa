#!/usr/bin/env bash
# transit を箱の上でビルドして箱ローカルレジストリ(127.0.0.1:5000)へ push。
# sukhi と同じ方式（kamal は build しない → deploy は `kamal deploy --skip-push`）。
# 箱ローカル registry は箱の localhost からしか見えないので、ローカルではなく箱で焼く。
#
#   export DEPLOY_HOST=<箱>
#   ./bin/build-on-box.sh [tag=v0]
#   kamal deploy --skip-push
set -euo pipefail

: "${DEPLOY_HOST:?export DEPLOY_HOST=<box ip/hostname> first  (kamal-arm64 = 217.142.242.103)}"
TAG="${1:-v0}"
REMOTE="rocky@${DEPLOY_HOST}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SHA="$(git -C "$HERE" rev-parse HEAD)"          # kamal は :<git-SHA> を deploy する → これも焼く
IMGBASE="127.0.0.1:5000/transit-f3liz"
REGPASS="$(grep '^REGISTRY_PASSWORD=' /Users/nyanrus/repos/sukhi-fedi/.kamal/secrets | cut -d= -f2)"

echo "→ ship code to ${REMOTE}:~/transit-build/ (生成データ・秘密は除外)"
rsync -az --delete \
  --exclude='.git' --exclude='.kamal/secrets' --exclude='config/tls' \
  --exclude='progress' --exclude='corrected' --exclude='daily.json' \
  --exclude='.tago_key' --exclude='*.log' \
  "${HERE}/" "${REMOTE}:~/transit-build/"

echo "→ login box registry (sukhi と同じ 127.0.0.1:5000, user sukhi)"
printf '%s' "$REGPASS" | ssh "${REMOTE}" "docker login 127.0.0.1:5000 -u sukhi --password-stdin >/dev/null"

echo "→ build + push on box  (${IMGBASE}:${TAG} , :${SHA})"
ssh "${REMOTE}" "cd ~/transit-build && docker build -t '${IMGBASE}:${TAG}' -t '${IMGBASE}:${SHA}' . && docker push '${IMGBASE}:${TAG}' && docker push '${IMGBASE}:${SHA}'"

echo "✓ ${IMGBASE}:${TAG} / :${SHA} pushed. 次: kamal deploy --skip-push"
