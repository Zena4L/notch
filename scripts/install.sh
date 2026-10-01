#!/bin/bash
# Installs (or updates) Notch from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/Zena4L/notch/HEAD/scripts/install.sh | bash
#
# Options (environment variables):
#   NOTCH_VERSION=1.0.0           install a specific version instead of the latest
#   NOTCH_INSTALL_DIR=~/Apps      install somewhere other than /Applications
#   NOTCH_NO_OPEN=1               don't open Notch afterwards
set -euo pipefail

REPO="Zena4L/notch"
APP_NAME="Notch.app"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
[ -t 1 ] || { bold=""; dim=""; green=""; red=""; reset=""; }
step() { printf '%s==>%s %s\n' "${bold}" "${reset}" "$*"; }
fail() { printf '%sError:%s %s\n' "${red}" "${reset}" "$*" >&2; exit 1; }

# --- Checks ---------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || fail "Notch runs on macOS only."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${macos_major}" -ge 14 ] || fail "Notch needs macOS 14 or later (you have $(sw_vers -productVersion))."
for tool in curl hdiutil ditto shasum; do
    command -v "${tool}" >/dev/null || fail "'${tool}' is missing."
done

# --- Find the release -----------------------------------------------------

if [ -n "${NOTCH_VERSION:-}" ]; then
    version="${NOTCH_VERSION#v}"
    api="https://api.github.com/repos/$REPO/releases/tags/v${version}"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi
if [ -n "${NOTCH_VERSION:-}" ]; then step "Finding Notch ${version}..."; else step "Finding the latest release..."; fi
status="$(curl -sSL -o "${TMPDIR:-/tmp}/notch-release.json" -w '%{http_code}' "${api}")" \
    || fail "Couldn't reach GitHub. Check your connection and try again."
release="$(cat "${TMPDIR:-/tmp}/notch-release.json")"; rm -f "${TMPDIR:-/tmp}/notch-release.json"
case "${status}" in
    200) ;;
    404)
        if [ -n "${NOTCH_VERSION:-}" ]; then fail "There is no Notch ${version}. See https://github.com/$REPO/releases"; fi
        fail "No releases found. See https://github.com/$REPO/releases" ;;
    403) fail "GitHub is rate-limiting requests from your network. Try again in a few minutes." ;;
    *)   fail "GitHub returned an error (${status}). Try again later." ;;
esac
dmg_url="$(printf '%s' "${release}" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "${dmg_url}" ] || fail "No Notch download found in that release."
sha_url="${dmg_url}.sha256"
version="$(basename "${dmg_url}" .dmg | sed 's/^Notch-//')"

# --- Download and verify --------------------------------------------------

work="$(mktemp -d)"
mount_point=""
cleanup() {
    [ -n "${mount_point}" ] && hdiutil detach -quiet "${mount_point}" 2>/dev/null || true
    rm -rf "${work}"
}
trap cleanup EXIT

step "Downloading Notch ${version}..."
curl -fL --progress-bar -o "${work}/Notch.dmg" "${dmg_url}" || fail "Download failed."

if expected="$(curl -fsSL "${sha_url}" 2>/dev/null | awk '{print $1}')" && [ -n "${expected}" ]; then
    actual="$(shasum -a 256 "${work}/Notch.dmg" | awk '{print $1}')"
    [ "${expected}" = "${actual}" ] || fail "The download is corrupted (checksum mismatch). Please try again."
    printf '    %schecksum verified%s\n' "${dim}" "${reset}"
fi

# --- Install --------------------------------------------------------------

dest="${NOTCH_INSTALL_DIR:-/Applications}"
if [ ! -w "${dest}" ] && [ -z "${NOTCH_INSTALL_DIR:-}" ]; then
    dest="$HOME/Applications"  # no admin rights: install just for this user
fi
mkdir -p "${dest}"

if pgrep -xq Notch; then
    step "Quitting the running Notch..."
    osascript -e 'tell application id "com.clementbogyah.Notch" to quit' >/dev/null 2>&1 || pkill -x Notch || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Notch || break; sleep 0.5; done
fi

step "Installing into ${dest}..."
mount_point="${work}/mount"
mkdir -p "${mount_point}"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "${mount_point}" "${work}/Notch.dmg" || fail "Couldn't open the downloaded disk image."
[ -d "${mount_point}/$APP_NAME" ] || fail "The disk image doesn't contain $APP_NAME."
rm -rf "${dest:?}/$APP_NAME"
ditto "${mount_point}/$APP_NAME" "${dest}/$APP_NAME"
# Downloads made with curl aren't marked as quarantined, but clear it in case an older copy was.
xattr -dr com.apple.quarantine "${dest}/$APP_NAME" 2>/dev/null || true

printf '%s✓ Notch %s is installed%s in %s\n' "${green}" "${version}" "${reset}" "${dest}"

if [ -z "${NOTCH_NO_OPEN:-}" ]; then
    open "${dest}/$APP_NAME"
    printf '  Look for the island over your notch and the icon in the menu bar.\n'
fi
