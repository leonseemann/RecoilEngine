#!/bin/bash
# Entry point of the BAR.app bundle: fetches game and lobby from the official
# BAR servers and starts the bundled engine with the BYAR-Chobby lobby.
set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/../Resources/engine" && pwd)"
BAR_DATA="${BAR_DATA:-$HOME/Library/Application Support/Beyond All Reason}"
LOG="$HOME/Library/Logs/BAR-launcher.log"
GAME_TAG="byar:test"
LOBBY_TAG="byar-chobby:test"

# the bundled fontconfig would otherwise look for its config in the Homebrew prefix
export FONTCONFIG_FILE="${FONTCONFIG_FILE:-$ENGINE_DIR/fonts.conf}"
export PRD_RAPID_USE_STREAMER=false
export PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz
export PRD_HTTP_SEARCH_URL=https://files-cdn.beyondallreason.dev/find

mkdir -p "$BAR_DATA" "$(dirname "$LOG")"
exec >"$LOG" 2>&1

notify() {
	osascript -e "display notification \"$1\" with title \"Beyond All Reason\"" || true
}

fail() {
	osascript -e "display alert \"Beyond All Reason\" message \"$1\n\nLog: $LOG\" as critical" || true
	exit 1
}

# release this app was built from, "<owner/repo> <tag>"; missing for local builds
check_app_update() {
	local release="$ENGINE_DIR/../app-release"
	[ -f "$release" ] || return 0
	local repo tag json latest url
	read -r repo tag < "$release"

	json="$(curl -fsS --max-time 5 "https://api.github.com/repos/$repo/releases/latest")" || return 0
	latest="$(plutil -extract tag_name raw -o - - <<< "$json")" || return 0
	url="$(plutil -extract html_url raw -o - - <<< "$json")" || return 0
	[ "$latest" != "$tag" ] || return 0

	if osascript -e "button returned of (display dialog \"Eine neue Version von BAR für Mac ist verfügbar ($latest, installiert: $tag).\n\nDie neue Version aus dem Download in den Programme-Ordner ziehen und die alte ersetzen.\" with title \"Beyond All Reason\" buttons {\"Später\", \"Herunterladen\"} default button \"Herunterladen\")" | grep -q Herunterladen; then
		open "$url"
	fi
}

update() {
	local prd="$ENGINE_DIR/pr-downloader"

	if [ ! -d "$BAR_DATA/packages" ]; then
		notify "Lade Spieldaten herunter, das kann einige Minuten dauern..."
	fi
	"$prd" --filesystem-writepath "$BAR_DATA" --download-game "$GAME_TAG" || return 1
	"$prd" --filesystem-writepath "$BAR_DATA" --download-game "$LOBBY_TAG" || return 1
}

configure() {
	local cfg="$BAR_DATA/springsettings.cfg"
	touch "$cfg"
	grep -q '^RapidTagResolutionOrder' "$cfg" || echo 'RapidTagResolutionOrder = repos-cdn.beyondallreason.dev;repos.beyondallreason.dev' >> "$cfg"

	[ -f "$BAR_DATA/chobby_config.json" ] || cat > "$BAR_DATA/chobby_config.json" <<'EOF'
{
  "server": {
    "address": "server4.beyondallreason.info",
    "port": 8200,
    "protocol": "spring",
    "serverName": "BAR"
  },
  "game": "byar"
}
EOF
}

check_app_update
if ! update; then
	# play offline with what is already there
	[ -d "$BAR_DATA/packages" ] || fail "Download der Spieldaten fehlgeschlagen. Besteht eine Internetverbindung?"
fi
configure

exec "$ENGINE_DIR/spring" --write-dir "$BAR_DATA" --menu "rapid://$LOBBY_TAG"
