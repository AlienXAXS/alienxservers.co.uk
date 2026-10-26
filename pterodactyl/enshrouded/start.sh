#!/bin/bash
# start_enshrouded.sh - launcher for Enshrouded on the Pterodactyl steamcmd:proton image.
#
# Runs AFTER the image entrypoint, which has already (a) updated the game through
# SteamCMD when AUTO_UPDATE=1 and (b) exported STEAM_COMPAT_CLIENT_INSTALL_PATH and
# STEAM_COMPAT_DATA_PATH. This script then:
#   1. refreshes steamclient.so from the SteamCMD that was just updated
#   2. makes sure libvulkan.so.1 exists (newer GE-Proton refuses to start without it)
#   3. installs / updates GE-Proton in ./GE-Proton (checksum verified when published,
#      and refused when it needs a newer glibc than the image has)
#   4. starts the server (inside xvfb-run when available) and follows its log
#
# Enshrouded 1.0 needs GE-Proton 11.x (Steamworks SDK 1.65), and GE-Proton 11 needs
# glibc >= 2.38. The stock ghcr.io/ptero-eggs/steamcmd:proton image is Debian bookworm
# (glibc 2.36), so it cannot run it: use a trixie based image such as
# ghcr.io/pelican-eggs/steamcmd:proton (the egg offers it as the default image).
# The layout mirrors the Enshrouded 1.0 setup of jsknnr/enshrouded-server v2.4.0
# (GE-Proton 11, STEAM_COMPAT_CLIENT_INSTALL_PATH = the SteamCMD directory).
#
# Optional environment variables (the egg provides them, defaults are used if missing):
#   GE_PROTON_AUTO_UPDATE  1 = look for a newer GE-Proton on every start (default 1)
#   GE_PROTON_VERSION      "latest" or a pinned tag such as GE-Proton11-11 (default latest)
#   USE_XVFB               1 = run under xvfb-run when it exists (default 1)

SERVER_DIR="${SERVER_DIR:-/home/container}"
cd "$SERVER_DIR" || exit 1

GE_PROTON_AUTO_UPDATE="${GE_PROTON_AUTO_UPDATE:-1}"
GE_PROTON_VERSION="${GE_PROTON_VERSION:-latest}"
GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom"
GE_DIR="$SERVER_DIR/GE-Proton"
LIB_DIR="$SERVER_DIR/lib"
LOG_FILE="./logs/enshrouded_server.log"

say() { echo "[launcher] $*"; }
host_glibc() { getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}'; }

# ---------------------------------------------------------------- environment
SRCDS_APPID="${SRCDS_APPID:-2278520}"
if [ -f "steamcmd/linux64/steamclient.so" ]; then
    # the image entrypoint points this at .steam/steam; the SteamCMD directory (which
    # SteamCMD keeps current) is what the working Enshrouded 1.0 setups use
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$SERVER_DIR/steamcmd"
else
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$SERVER_DIR/.steam/steam}"
fi
export STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-$SERVER_DIR/.steam/steam/steamapps/compatdata/$SRCDS_APPID}"
mkdir -p "$STEAM_COMPAT_DATA_PATH" logs .config/protonfixes

# ------------------------------------------- 1. fresh steamclient.so everywhere
# The egg's install script copies steamclient.so only once. SteamCMD itself
# updates on every boot, so copy its current build to every place that is read:
#   .steam/sdk{32,64}            - native Steam layout
#   .steam/steam/linux{32,64}    - STEAM_COMPAT_CLIENT_INSTALL_PATH, used by Proton
refresh_steamclient() {
    local bits src dst copied=0
    for bits in 64 32; do
        src="steamcmd/linux${bits}/steamclient.so"
        [ -f "$src" ] || continue
        for dst in ".steam/sdk${bits}" ".steam/steam/linux${bits}"; do
            mkdir -p "$dst" && cp -f "$src" "$dst/steamclient.so" && ln -sf steamclient.so "$dst/steamservice.so" && copied=1
        done
    done
    [ "$copied" = 1 ] || say "WARNING: steamcmd/linux64/steamclient.so not found, nothing refreshed"
}

# ------------------------------------------------------------ 2. libvulkan.so.1
vulkan_ok() {
    LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH" \
        python3 -c "import ctypes; ctypes.CDLL('libvulkan.so.1')" >/dev/null 2>&1
}

ensure_vulkan() {
    vulkan_ok && return 0
    say "libvulkan.so.1 is missing, fetching the Debian bookworm package"
    local tmp deb base name
    tmp=$(mktemp -d) || return 1
    (
        cd "$tmp" || exit 1
        deb=""
        # apt lists were created when the image was built, so this usually works as non-root
        if apt-get download libvulkan1 >/dev/null 2>&1; then
            deb=$(ls libvulkan1_*_amd64.deb 2>/dev/null | head -n1)
        fi
        if [ -z "$deb" ]; then
            base="https://deb.debian.org/debian/pool/main/v/vulkan-loader/"
            name=$(curl -fsSL "$base" | grep -o 'libvulkan1_1\.3\.239[^"<>]*_amd64\.deb' | sort -u | tail -n1)
            [ -n "$name" ] && curl -fsSLO "$base$name" && deb="$name"
        fi
        [ -n "$deb" ] || exit 1
        dpkg-deb -x "$deb" ./x || exit 1
        mkdir -p "$LIB_DIR"
        cp -fL ./x/usr/lib/x86_64-linux-gnu/libvulkan.so.1 "$LIB_DIR/libvulkan.so.1"
    )
    local rc=$?
    rm -rf "$tmp"
    if [ "$rc" != 0 ] || ! vulkan_ok; then
        say "WARNING: could not provide libvulkan.so.1; GE-Proton may fail to start"
        return 1
    fi
    say "libvulkan.so.1 installed to $LIB_DIR"
}

# ---------------------------------------------------------------- 3. GE-Proton
latest_tag() {
    # /releases/latest redirects to /releases/tag/<TAG>; avoids the rate-limited API
    curl -fsSIL -o /dev/null -w '%{url_effective}' "$GE_REPO/releases/latest" 2>/dev/null | sed 's#.*/##'
}

install_ge() {
    local tag="$1" work rc
    work=$(mktemp -d -p "$SERVER_DIR" .ge-tmp-XXXXXX) || return 1
    (
        cd "$work" || exit 1
        # GE-Proton 11 ships as <tag>-x86_64.tar.gz, older releases as <tag>.tar.gz
        asset=""
        for cand in "$tag-x86_64.tar.gz" "$tag.tar.gz"; do
            if curl -fsSL -o "$cand" "$GE_REPO/releases/download/$tag/$cand" 2>/dev/null; then
                asset="$cand"
                break
            fi
        done
        [ -n "$asset" ] || { echo "[launcher] no download found for $tag (tried $tag-x86_64.tar.gz and $tag.tar.gz)"; exit 1; }
        echo "[launcher] downloaded $asset"
        # Verify when a checksum file is published; skip with a warning when it is not.
        sumfile="${asset%.tar.gz}.sha512sum"
        if curl -fsSL -o "$sumfile" "$GE_REPO/releases/download/$tag/$sumfile" 2>/dev/null; then
            want=$(awk '{print $1; exit}' "$sumfile")
            got=$(sha512sum "$asset" | awk '{print $1}')
            [ -n "$want" ] && [ "$want" = "$got" ] || { echo "[launcher] checksum mismatch for $asset"; exit 1; }
        else
            echo "[launcher] no checksum file for $asset, skipping verification"
        fi
        mkdir new && tar -xzf "$asset" -C new --strip-components=1 || exit 1
        rm -f "$asset"
        [ -f new/proton ] || exit 1
        # refuse builds whose Wine needs a newer glibc than this image provides
        need=$(grep -a -o 'GLIBC_2\.[0-9]\+' new/files/lib/wine/x86_64-unix/ntdll.so 2>/dev/null | sed 's/GLIBC_//' | sort -V | tail -n1)
        have=$(host_glibc)
        if [ -n "$need" ] && [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -n1)" != "$have" ]; then
            echo "[launcher] $tag needs glibc $need, this image has $have. Use a Debian trixie based image."
            exit 7
        fi
        echo "$tag" > new/.ge_tag
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 7 ] && echo "$tag glibc-$(host_glibc)" > "$SERVER_DIR/.ge_rejected"
        rm -rf "$work"
        return 1
    fi
    rm -rf "$GE_DIR.old"
    [ -d "$GE_DIR" ] && mv "$GE_DIR" "$GE_DIR.old"
    if mv "$work/new" "$GE_DIR"; then
        rm -rf "$work" "$GE_DIR.old"
    else
        [ -d "$GE_DIR.old" ] && mv "$GE_DIR.old" "$GE_DIR"
        rm -rf "$work"
        return 1
    fi
}

setup_proton() {
    local cur="" tag=""
    [ -f "$GE_DIR/.ge_tag" ] && cur=$(cat "$GE_DIR/.ge_tag")

    if [ "$GE_PROTON_VERSION" = "latest" ]; then
        # with auto-update off, an existing GE-Proton or the one bundled in the image is used as is
        if [ "$GE_PROTON_AUTO_UPDATE" = "1" ] || { [ ! -f "$GE_DIR/proton" ] && ! command -v proton >/dev/null 2>&1; }; then
            tag=$(latest_tag)
            [ -n "$tag" ] || say "could not determine the latest GE-Proton (no network?)"
        fi
    else
        tag="$GE_PROTON_VERSION"
    fi

    if [ -n "$tag" ] && ! [[ "$tag" =~ ^GE-Proton[0-9]+-[0-9]+$ ]]; then
        say "WARNING: '$tag' is not a valid GE-Proton tag, ignoring"
        tag=""
    fi

    if [ -n "$tag" ] && [ "$(cat "$SERVER_DIR/.ge_rejected" 2>/dev/null)" = "$tag glibc-$(host_glibc)" ]; then
        say "skipping $tag: it needs a newer glibc than this image has ($(host_glibc))"
        tag=""
    fi

    if [ -n "$tag" ] && [ "$tag" != "$cur" ]; then
        say "installing $tag (installed: ${cur:-none})"
        if install_ge "$tag"; then
            say "$tag installed"
        else
            say "WARNING: installing $tag failed, keeping ${cur:-the Proton from the image}"
        fi
    fi

    if [ -f "$GE_DIR/proton" ]; then
        PROTON_BIN="$GE_DIR/proton"
    else
        PROTON_BIN="$(command -v proton)"
        say "using the Proton bundled in the image: ${PROTON_BIN:-<none>}"
    fi
    [ -n "$PROTON_BIN" ] || { say "ERROR: no Proton available"; exit 1; }
}

# --------------------------------------------------------------------- run it
refresh_steamclient
ensure_vulkan
setup_proton

export LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH"

say "Proton: $PROTON_BIN ($( [ -f "$GE_DIR/.ge_tag" ] && cat "$GE_DIR/.ge_tag" || echo image )), glibc $(host_glibc), client path $STEAM_COMPAT_CLIENT_INSTALL_PATH"
for f in steamcmd/linux64/steamclient.so .steam/sdk64/steamclient.so .steam/steam/linux64/steamclient.so; do
    [ -f "$f" ] && say "$(ls -l --time-style=long-iso "$f" | awk '{print $5, $6, $7, $8}')"
done

# GE-Proton 11 needs a display; Xalia (controller helper) is useless on a server
export PROTON_USE_XALIA=0
export WINEDEBUG="${WINEDEBUG:--all}"
RUN_PREFIX=()
if [ "${USE_XVFB:-1}" = "1" ] && command -v xvfb-run >/dev/null 2>&1; then
    RUN_PREFIX=(xvfb-run -a)
fi

rm -f "$LOG_FILE"
"${RUN_PREFIX[@]}" "$PROTON_BIN" run ./enshrouded_server.exe &
ENS_PID=$!
tail -c0 -F "$LOG_FILE" --pid=$ENS_PID
wait $ENS_PID
exit $?
