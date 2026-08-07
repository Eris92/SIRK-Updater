#!/usr/bin/env bash
set -euo pipefail

REPO="Eris92/SIRK-Updater"
INSTALL_ROOT="${SIRK_UPDATER_INSTALL_ROOT:-/opt/sirk/updater}"
STATE_ROOT="${SIRK_UPDATER_STATE_ROOT:-/var/lib/sirk-updater}"
SERVICE_NAME="sirk-updater.service"

log() { printf '[INFO] %s\n' "$*"; }
ok()  { printf '[OK] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v unzip >/dev/null 2>&1 || die "unzip is required."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."
command -v dotnet >/dev/null 2>&1 || die ".NET 10 runtime is required."

dotnet --list-runtimes | grep -Eq '^Microsoft\.NETCore\.App 10\.' || die "Microsoft.NETCore.App 10.0 runtime is required."
ok "Microsoft.NETCore.App 10 runtime detected."

tmp="$(mktemp -d /tmp/sirk-updater-install.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

log "Resolving latest GitHub Release metadata."
release_json="$tmp/release.json"
curl --fail --silent --show-error --location \
  --retry 4 --retry-delay 2 --retry-all-errors \
  "https://api.github.com/repos/${REPO}/releases/latest" -o "$release_json"

readarray -t resolved < <(python3 - "$release_json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8-sig') as f:
    data = json.load(f)
tag = data.get('tag_name') or ''
assets = data.get('assets') or []
zip_asset = next((a for a in assets if (a.get('name') or '').endswith('-linux-x64.zip')), None)
sha_asset = next((a for a in assets if (a.get('name') or '').endswith('-linux-x64.zip.sha256')), None)
if not tag or not zip_asset or not sha_asset:
    raise SystemExit('Latest release does not contain linux-x64 assets.')
print(tag)
print(zip_asset['name'])
print(zip_asset['browser_download_url'])
print(sha_asset['browser_download_url'])
PY
)

[[ "${#resolved[@]}" -eq 4 ]] || die "Unable to resolve linux-x64 release assets."
tag="${resolved[0]}"
zip_name="${resolved[1]}"
zip_url="${resolved[2]}"
sha_url="${resolved[3]}"
ok "Release resolved: ${tag}"

zip_path="$tmp/$zip_name"
sha_path="$tmp/$zip_name.sha256"
log "Downloading ${zip_name}."
curl --fail --silent --show-error --location --retry 4 --retry-delay 2 --retry-all-errors "$zip_url" -o "$zip_path"
curl --fail --silent --show-error --location --retry 4 --retry-delay 2 --retry-all-errors "$sha_url" -o "$sha_path"

expected="$(awk 'NR==1 {print tolower($1)}' "$sha_path")"
actual="$(sha256sum "$zip_path" | awk '{print tolower($1)}')"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "Release SHA-256 file is invalid."
[[ "$actual" == "$expected" ]] || die "SHA-256 mismatch. Expected ${expected}, actual ${actual}."
ok "SHA-256 verified: ${actual}"

payload="$tmp/payload"
mkdir -p "$payload"
unzip -q "$zip_path" -d "$payload"
[[ -f "$payload/release-manifest.json" ]] || die "release-manifest.json is missing."
[[ -f "$payload/SirkUpdater.Service" ]] || die "SirkUpdater.Service is missing."
[[ -f "$payload/SirkUpdater" ]] || die "SirkUpdater CLI is missing."

version="$(python3 - "$payload/release-manifest.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8-sig') as f:
    d = json.load(f)
if d.get('applicationId') != 'sirk-updater': raise SystemExit('Invalid applicationId.')
if d.get('architecture') != 'linux-x64': raise SystemExit('Invalid architecture.')
if d.get('targetFramework') != 'net10.0': raise SystemExit('Invalid targetFramework.')
if d.get('deploymentMode') != 'framework-dependent': raise SystemExit('Invalid deploymentMode.')
print(d.get('version') or '')
PY
)"
[[ -n "$version" ]] || die "Release version is missing."
ok "Payload validated: version ${version}."

if systemctl list-unit-files "$SERVICE_NAME" --no-legend 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
  systemctl stop "$SERVICE_NAME" || true
fi

mkdir -p "$(dirname "$INSTALL_ROOT")" "$STATE_ROOT"
rm -rf "$INSTALL_ROOT.new"
mkdir -p "$INSTALL_ROOT.new"
cp -a "$payload/." "$INSTALL_ROOT.new/"
chmod 0755 "$INSTALL_ROOT.new/SirkUpdater" "$INSTALL_ROOT.new/SirkUpdater.Service"
rm -rf "$INSTALL_ROOT.old"
if [[ -d "$INSTALL_ROOT" ]]; then mv "$INSTALL_ROOT" "$INSTALL_ROOT.old"; fi
mv "$INSTALL_ROOT.new" "$INSTALL_ROOT"
rm -rf "$INSTALL_ROOT.old"
ln -sfn "$INSTALL_ROOT/SirkUpdater" /usr/local/bin/sirk-updater

cat >"/etc/systemd/system/${SERVICE_NAME}" <<UNIT
[Unit]
Description=SIRK Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${INSTALL_ROOT}/SirkUpdater.Service
WorkingDirectory=${INSTALL_ROOT}
Restart=on-failure
RestartSec=5
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME" || die "${SERVICE_NAME} did not start."

printf 'Version : %s\n' "$version"
printf 'Service : %s\n' "$(systemctl is-active "$SERVICE_NAME")"
printf 'CLI     : %s\n' "$INSTALL_ROOT/SirkUpdater"
printf 'SIRK_UPDATER_RELEASE_V2_LINUX_OK\n'
