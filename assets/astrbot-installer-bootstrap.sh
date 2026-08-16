#!/usr/bin/env bash
# Immutable bootstrap for the signed AstrBot Android shared installer.
# It intentionally contains only update, verification, and migration logic.

set -euo pipefail

INSTALLER_OWNER="MuFengDR"
INSTALLER_REPO="AstrBot-Android-Scripts"
INSTALLER_FORMAT="astrbot-android-installer-v1"
BOOTSTRAP_VERSION="0.1.0"
STATE_DIR="/root/.astrbot-android/installer"
CURRENT_DIR="$STATE_DIR/current"
CURRENT_SCRIPT="$CURRENT_DIR/astrbot-startup.sh"
PUBLIC_KEY_FILE="$STATE_DIR/installer-public.pem"
RESOLVED_GITHUB_PROXY=""

log() { printf '[AstrBot Installer] %s\n' "$*"; }
fail() { printf '[AstrBot Installer] ERROR: %s\n' "$*" >&2; exit 1; }

github_url() {
  local asset="$1"
  local url="https://github.com/$INSTALLER_OWNER/$INSTALLER_REPO/releases/latest/download/$asset"
  local proxy="${RESOLVED_GITHUB_PROXY:-}"
  case "$proxy" in
    '') printf '%s\n' "$url" ;;
    https://*|http://*) printf '%s/%s\n' "${proxy%/}" "$url" ;;
    *) fail "Invalid GitHub proxy value: $proxy" ;;
  esac
}

resolve_github_proxy() {
  local configured="${ASTRBOT_GITHUB_PROXY:-direct}" candidate status
  case "$configured" in
    ''|direct)
      RESOLVED_GITHUB_PROXY=""
      return 0
      ;;
    https://*|http://*)
      RESOLVED_GITHUB_PROXY="${configured%/}"
      log "Using configured GitHub proxy: $RESOLVED_GITHUB_PROXY"
      return 0
      ;;
    auto) ;;
    *) fail "Invalid GitHub proxy value: $configured" ;;
  esac

  for candidate in \
    https://ghfast.top \
    https://gh-proxy.com \
    https://ghproxy.net \
    https://ghproxy.cc \
    https://gh.dpik.top \
    https://gh.monlor.com \
    https://gh.chjina.com \
    https://github.boki.moe \
    https://gh.jasonzeng.dev \
    https://gh.geekertao.top \
    https://gh.nxnow.top \
    https://down.npee.cn; do
    status="$(curl -fL --connect-timeout 10 --max-time 20 -o /dev/null -s -w '%{http_code}' "$candidate/https://raw.githubusercontent.com/astral-sh/uv/main/README.md" || true)"
    if [ "$status" = "200" ]; then
      RESOLVED_GITHUB_PROXY="$candidate"
      log "Using GitHub proxy: $RESOLVED_GITHUB_PROXY"
      return 0
    fi
  done
  log 'No GitHub proxy responded; trying a direct connection.'
}

ensure_tools() {
  local command package
  local missing_packages=()
  for command in curl openssl tar sha256sum base64; do
    command -v "$command" >/dev/null 2>&1 && continue
    case "$command" in
      sha256sum|base64) package="coreutils" ;;
      *) package="$command" ;;
    esac
    [[ " ${missing_packages[*]} " == *" $package "* ]] || \
      missing_packages+=("$package")
  done
  # The certificate bundle is what curl actually needs.  dpkg can briefly
  # report an interrupted state even when the usable bundle already exists.
  [ -s /etc/ssl/certs/ca-certificates.crt ] || \
    missing_packages+=(ca-certificates)
  [ "${#missing_packages[@]}" -eq 0 ] && return 0

  log "Installing bootstrap requirements: ${missing_packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update || true
  apt-get -o Acquire::ForceIPv4=true install -y "${missing_packages[@]}"
}

write_public_key() {
  mkdir -p "$STATE_DIR"
  cat > "$PUBLIC_KEY_FILE" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAHDetO46oTvQSJ7mPKwdhLazNgXqDRVpU3nWrv1nmMU8=
-----END PUBLIC KEY-----
EOF
  if grep -q '__ASTRBOT_INSTALLER_ED25519_PUBLIC_KEY__' "$PUBLIC_KEY_FILE"; then
    fail 'The installer signing public key has not been configured in this APK.'
  fi
  chmod 600 "$PUBLIC_KEY_FILE"
}

manifest_value() {
  local key="$1"
  local file="$2"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n 1
}

validate_manifest() {
  local manifest="$1"
  local signature="$2"
  local artifact="$3"
  local format declared sha version
  format="$(manifest_value format "$manifest")"
  declared="$(manifest_value artifact "$manifest")"
  sha="$(manifest_value sha256 "$manifest")"
  version="$(manifest_value version "$manifest")"

  [ "$format" = "$INSTALLER_FORMAT" ] || fail 'Unsupported installer manifest format.'
  [ "$declared" = "$artifact" ] || fail 'Manifest artifact name does not match the requested payload.'
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail 'Installer manifest version must be semantic version major.minor.patch.'
  case "$artifact" in
    astrbot-installer-v*.tar.gz) ;;
    *) fail 'Invalid installer artifact name.' ;;
  esac
  case "$sha" in
    *[!0-9a-fA-F]*|'') fail 'Manifest SHA-256 is invalid.' ;;
  esac
  [ "${#sha}" -eq 64 ] || fail 'Manifest SHA-256 must contain 64 hexadecimal characters.'

  openssl pkeyutl -verify -rawin -pubin -inkey "$PUBLIC_KEY_FILE" \
    -in "$manifest" -sigfile "$signature" >/dev/null 2>&1 || \
    fail 'Installer manifest signature verification failed.'
}

archive_paths_are_safe() {
  tar -tzf "$1" | awk '
    $0 == "" || $0 ~ /^\// || $0 ~ /(^|\/)\.\.?(\/|$)/ { exit 1 }
  '
}

reject_installer_downgrade() {
  local manifest="$1"
  local current incoming
  local -a current_parts incoming_parts
  local index
  [ -f "$STATE_DIR/version" ] || return 0
  current="$(cat "$STATE_DIR/version" 2>/dev/null || true)"
  incoming="$(manifest_value version "$manifest")"
  [ -n "$current" ] || return 0
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [ "$current" = "$incoming" ] && return 0

  IFS='.' read -r -a current_parts <<< "$current"
  IFS='.' read -r -a incoming_parts <<< "$incoming"
  for index in 0 1 2; do
    if (( 10#${incoming_parts[index]} < 10#${current_parts[index]} )); then
      fail "Refusing signed installer downgrade from $current to $incoming."
    fi
    if (( 10#${incoming_parts[index]} > 10#${current_parts[index]} )); then
      return 0
    fi
  done
  return 0
}

verify_payload() {
  local payload="$1"
  local manifest="$2"
  local expected actual
  expected="$(manifest_value sha256 "$manifest")"
  actual="$(sha256sum "$payload" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail 'Installer payload SHA-256 verification failed.'
}

install_payload() (
  local payload="$1"
  local manifest="$2"
  local signature="$3"
  local stage previous
  stage="$(mktemp -d "$STATE_DIR/.stage.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT

  archive_paths_are_safe "$payload" || fail 'Installer archive contains an unsafe path.'
  tar -tzf "$payload" | grep -qx 'astrbot-installer/astrbot-startup.sh' || \
    fail 'Installer archive has an unexpected layout.'
  reject_installer_downgrade "$manifest"
  tar -xzf "$payload" -C "$stage" --no-same-owner --no-same-permissions
  [ -f "$stage/astrbot-installer/astrbot-startup.sh" ] || fail 'Installer archive is missing the runtime script.'
  chmod 700 "$stage/astrbot-installer/astrbot-startup.sh"

  rm -rf "$STATE_DIR/current.new"
  mv "$stage/astrbot-installer" "$STATE_DIR/current.new"
  previous="$STATE_DIR/previous-$(date +%Y%m%d-%H%M%S)"
  [ -d "$CURRENT_DIR" ] && mv "$CURRENT_DIR" "$previous"
  mv "$STATE_DIR/current.new" "$CURRENT_DIR"
  cp "$manifest" "$STATE_DIR/installed-manifest.json"
  cp "$signature" "$STATE_DIR/installed-manifest.sig"
  manifest_value version "$manifest" > "$STATE_DIR/version"
  log "Installed shared installer $(cat "$STATE_DIR/version" 2>/dev/null || echo unknown)."
)

download_manifest() {
  local destination="$1"
  local manifest="$destination/manifest.json"
  local signature="$destination/manifest.sig"
  local artifact
  mkdir -p "$destination"
  curl -fL --connect-timeout 20 --max-time 120 "$(github_url manifest.json)" -o "$manifest" || \
    fail 'Could not download the installer manifest.'
  curl -fL --connect-timeout 20 --max-time 120 "$(github_url manifest.sig)" -o "$signature" || \
    fail 'Could not download the installer manifest signature.'
  artifact="$(manifest_value artifact "$manifest")"
  validate_manifest "$manifest" "$signature" "$artifact"
  printf '%s\n' "$artifact"
}

download_release() {
  local destination="$1"
  local artifact
  artifact="$(download_manifest "$destination")"
  curl -fL --connect-timeout 20 --max-time 600 "$(github_url "$artifact")" -o "$destination/$artifact" || \
    fail 'Could not download the installer payload.'
  verify_payload "$destination/$artifact" "$destination/manifest.json"
  printf '%s\n' "$artifact"
}

migrate_legacy_settings() {
  local config_dir="/root/.config/astrbot-android"
  local config_file="$config_dir/installer.env"
  local flags_dir="$config_dir/flags"
  local legacy="/root/astrbot-startup.sh"
  local custom encoded
  [ -f "$legacy" ] || return 0
  mkdir -p "$flags_dir"
  if [ ! -f "$config_file" ]; then
    custom="$(sed -n 's/^CUSTOM_GIT_CLONE="\(.*\)"$/\1/p' "$legacy" | head -n 1)"
    encoded="$(printf '%s' "$custom" | base64 | tr -d '\n')"
    printf 'CUSTOM_GIT_CLONE_B64=%s\n' "$encoded" > "$config_file"
    log 'Migrated the legacy custom Git clone setting.'
  fi
  if grep -qx 'REINSTALL_PLUGINS_FLAG=1' "$legacy" 2>/dev/null; then
    : > "$flags_dir/reinstall-plugins"
    log 'Migrated the legacy plugin dependency reinstall flag.'
  fi
}

fetch_and_install() (
  local temporary artifact
  temporary="$(mktemp -d "$STATE_DIR/.download.XXXXXX")"
  trap 'rm -rf "$temporary"' EXIT
  artifact="$(download_release "$temporary")"
  install_payload "$temporary/$artifact" "$temporary/manifest.json" "$temporary/manifest.sig"
)

import_and_install() (
  local package="$1"
  local temporary artifact
  [ -f "$package" ] || fail "Offline installer package does not exist: $package"
  temporary="$(mktemp -d "$STATE_DIR/.import.XXXXXX")"
  trap 'rm -rf "$temporary"' EXIT
  archive_paths_are_safe "$package" || fail 'Offline installer package contains an unsafe path.'
  tar -xzf "$package" -C "$temporary" || fail 'Could not unpack the offline installer package.'
  [ -f "$temporary/manifest.json" ] && [ -f "$temporary/manifest.sig" ] || \
    fail 'Offline installer package is missing its signed manifest.'
  artifact="$(manifest_value artifact "$temporary/manifest.json")"
  [ -f "$temporary/$artifact" ] || fail 'Offline installer package is missing its payload.'
  validate_manifest "$temporary/manifest.json" "$temporary/manifest.sig" "$artifact"
  verify_payload "$temporary/$artifact" "$temporary/manifest.json"
  install_payload "$temporary/$artifact" "$temporary/manifest.json" "$temporary/manifest.sig"
)

ensure_installer() {
  local version
  version="$(cat "$STATE_DIR/version" 2>/dev/null || true)"
  if [ -x "$CURRENT_SCRIPT" ] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "Using installed shared installer $version."
    return 0
  fi
  log 'No shared installer is installed; downloading the first verified version.'
  fetch_and_install
}

require_installer() {
  local version
  [ -x "$CURRENT_SCRIPT" ] || \
    fail 'No verified installer is installed. Download, update, or import the installer first.'
  version="$(cat "$STATE_DIR/version" 2>/dev/null || true)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail 'The installed installer version is invalid. Update or import the installer again.'
}

check_update() (
  local temporary artifact latest current
  temporary="$(mktemp -d "$STATE_DIR/.check.XXXXXX")"
  trap 'rm -rf "$temporary"' EXIT
  artifact="$(download_manifest "$temporary")"
  latest="$(manifest_value version "$temporary/manifest.json")"
  current="$(cat "$STATE_DIR/version" 2>/dev/null || echo not-installed)"
  log "Current version: $current"
  log "Verified remote version: ${latest:-unknown}"
  log 'No local installer files were changed.'
)

usage() {
  cat <<'EOF'
Usage:
  astrbot-installer-bootstrap.sh --prepare
  astrbot-installer-bootstrap.sh --ensure
  astrbot-installer-bootstrap.sh --check
  astrbot-installer-bootstrap.sh --update
  astrbot-installer-bootstrap.sh --import /path/to/offline-package.tar.gz
  astrbot-installer-bootstrap.sh --run --step <base|uv|napcat|astrbot|opencode|all>
EOF
}

main() {
  local command="${1:---help}"
  case "$command" in
    --prepare)
      ensure_tools
      log 'Bootstrap requirements are ready.'
      ;;
    --ensure|--check|--update)
      ensure_tools
      resolve_github_proxy
      write_public_key
      migrate_legacy_settings
      case "$command" in
        --ensure) ensure_installer ;;
        --check) check_update ;;
        --update) fetch_and_install ;;
      esac
      ;;
    --import)
      [ "$#" -eq 2 ] || fail '--import requires an offline package path.'
      ensure_tools
      write_public_key
      migrate_legacy_settings
      import_and_install "$2"
      ;;
    --run)
      shift
      require_installer
      exec "$CURRENT_SCRIPT" "$@"
      ;;
    --help|-h|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
