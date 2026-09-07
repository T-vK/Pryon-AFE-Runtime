#!/bin/sh
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

command -v act >/dev/null 2>&1 || {
  echo 'local-ci: missing dependency: act' >&2
  echo '  Linux: install https://github.com/nektos/act (or use the project package manager)' >&2
  echo '  macOS: brew install act' >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo 'local-ci: missing dependency: Docker (required by act)' >&2
  echo '  Linux: install Docker Engine or Docker Desktop' >&2
  echo '  macOS: brew install --cask docker' >&2
  exit 1
}

IMAGE=${ACT_IMAGE:-catthehacker/ubuntu:act-latest}
EVENT=${ACT_EVENT:-pull_request}
CONTAINER_OPTIONS=${ACT_CONTAINER_OPTIONS:--v /usr/bin/shellcheck:/usr/local/bin/shellcheck:ro}

run_job() {
  JOB=$1
  OPTIONS=$CONTAINER_OPTIONS
  EXTRA_ENV='--env ACT_SKIP_SHELLCHECK_INSTALL=1'
  if [ "$JOB" = android ]; then
    OPTIONS="$OPTIONS -v /opt/android-sdk:/opt/android-sdk:ro"
    OPTIONS="$OPTIONS -v /usr/lib/jvm/java-17-openjdk-amd64:/usr/lib/jvm/java-17-openjdk-amd64:ro"
    OPTIONS="$OPTIONS -v /etc/java-17-openjdk:/etc/java-17-openjdk:ro"
    EXTRA_ENV="$EXTRA_ENV --env ACT_SKIP_JAVA_INSTALL=1 --env ACT_SKIP_ANDROID_SETUP=1 --env ACT_SKIP_ANDROID_NDK_INSTALL=1"
    EXTRA_ENV="$EXTRA_ENV --env JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
    EXTRA_ENV="$EXTRA_ENV --env ANDROID_HOME=/opt/android-sdk --env ANDROID_SDK_ROOT=/opt/android-sdk"
    EXTRA_ENV="$EXTRA_ENV --env ANDROID_NDK_HOME=/opt/android-sdk/ndk/26.3.11579264"
  fi
  echo "local-ci: running $JOB job in $IMAGE"
  act "$EVENT" -W .github/workflows/ci.yml -j "$JOB" \
    -P "ubuntu-latest=$IMAGE" \
    $EXTRA_ENV \
    --container-options "$OPTIONS" \
    --container-architecture linux/amd64
  echo "local-ci: $JOB job passed"
}

echo "local-ci: listing jobs from .github/workflows/ci.yml"
act -l -W .github/workflows/ci.yml
run_job host
run_job scripts

if [ "${ACT_ANDROID:-0}" = 1 ]; then
  run_job android
fi

cat <<'EOF'
local-ci: Android is opt-in: ACT_ANDROID=1 make local-ci
The release workflow is not run locally because it creates tags/releases; use
  npx semantic-release --dry-run for a non-publishing release check.
EOF
