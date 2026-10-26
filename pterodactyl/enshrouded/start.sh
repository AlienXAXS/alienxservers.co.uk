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

# Timestamped so a quiet console shows how long the current step has been running.
say() { echo "[launcher $(date '+%H:%M:%S')] $*"; }
host_glibc() { getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}'; }

say "starting launcher in $SERVER_DIR"
cd "$SERVER_DIR" || { say "ERROR: cannot cd to $SERVER_DIR"; exit 1; }

GE_PROTON_AUTO_UPDATE="${GE_PROTON_AUTO_UPDATE:-1}"
GE_PROTON_VERSION="${GE_PROTON_VERSION:-latest}"
GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom"
GE_DIR="$SERVER_DIR/GE-Proton"
LIB_DIR="$SERVER_DIR/lib"
LOG_FILE="./logs/enshrouded_server.log"

say "settings: GE_PROTON_VERSION=$GE_PROTON_VERSION GE_PROTON_AUTO_UPDATE=$GE_PROTON_AUTO_UPDATE USE_XVFB=${USE_XVFB:-1}"

# ---------------------------------------------------------------- environment
say "[0/4] preparing environment"
SRCDS_APPID="${SRCDS_APPID:-2278520}"
say "app id: $SRCDS_APPID"
if [ -f "steamcmd/linux64/steamclient.so" ]; then
    # the image entrypoint points this at .steam/steam; the SteamCMD directory (which
    # SteamCMD keeps current) is what the working Enshrouded 1.0 setups use
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$SERVER_DIR/steamcmd"
    say "steamcmd/linux64/steamclient.so found, using the SteamCMD directory as the Steam client path"
else
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$SERVER_DIR/.steam/steam}"
    say "no SteamCMD steamclient.so, falling back to the image's client path"
fi
say "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH"
export STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-$SERVER_DIR/.steam/steam/steamapps/compatdata/$SRCDS_APPID}"
say "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
if [ -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
    say "existing Proton prefix found"
else
    say "no Proton prefix yet; the first start will create one (this can take a few minutes)"
fi
mkdir -p "$STEAM_COMPAT_DATA_PATH" logs .config/protonfixes

# ------------------------------------------- 1. fresh steamclient.so everywhere
# The egg's install script copies steamclient.so only once. SteamCMD itself
# updates on every boot, so copy its current build to every place that is read:
#   .steam/sdk{32,64}            - native Steam layout
#   .steam/steam/linux{32,64}    - STEAM_COMPAT_CLIENT_INSTALL_PATH, used by Proton
refresh_steamclient() {
    say "[1/4] refreshing steamclient.so from SteamCMD"
    local bits src dst copied=0
    for bits in 64 32; do
        src="steamcmd/linux${bits}/steamclient.so"
        if [ ! -f "$src" ]; then
            say "  $src not found, skipping ${bits}-bit"
            continue
        fi
        for dst in ".steam/sdk${bits}" ".steam/steam/linux${bits}"; do
            if mkdir -p "$dst" && cp -f "$src" "$dst/steamclient.so" && ln -sf steamclient.so "$dst/steamservice.so"; then
                say "  copied $src -> $dst/steamclient.so"
                copied=1
            else
                say "  WARNING: failed to copy $src -> $dst"
            fi
        done
    done
    if [ "$copied" = 1 ]; then
        say "steamclient.so refresh done"
    else
        say "WARNING: steamcmd/linux64/steamclient.so not found, nothing refreshed"
    fi
}

# ------------------------------------------------------------ 2. libvulkan.so.1
vulkan_ok() {
    LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH" \
        python3 -c "import ctypes; ctypes.CDLL('libvulkan.so.1')" >/dev/null 2>&1
}

ensure_vulkan() {
    say "[2/4] checking for libvulkan.so.1"
    if vulkan_ok; then
        say "libvulkan.so.1 is available, nothing to do"
        return 0
    fi
    say "libvulkan.so.1 is missing, fetching the Debian bookworm package"
    local tmp deb base name
    tmp=$(mktemp -d) || { say "WARNING: mktemp failed, cannot fetch libvulkan"; return 1; }
    (
        cd "$tmp" || exit 1
        deb=""
        # apt lists were created when the image was built, so this usually works as non-root
        say "  trying apt-get download libvulkan1"
        if apt-get download libvulkan1 >/dev/null 2>&1; then
            deb=$(ls libvulkan1_*_amd64.deb 2>/dev/null | head -n1)
            [ -n "$deb" ] && say "  apt-get download succeeded: $deb"
        else
            say "  apt-get download failed"
        fi
        if [ -z "$deb" ]; then
            base="https://deb.debian.org/debian/pool/main/v/vulkan-loader/"
            say "  looking up the package on deb.debian.org"
            name=$(curl -fsSL "$base" | grep -o 'libvulkan1_1\.3\.239[^"<>]*_amd64\.deb' | sort -u | tail -n1)
            if [ -n "$name" ]; then
                say "  downloading $name"
                curl -fsSLO "$base$name" && deb="$name" || say "  download of $name failed"
            else
                say "  no matching package found on deb.debian.org"
            fi
        fi
        [ -n "$deb" ] || { say "  no libvulkan1 package obtained"; exit 1; }
        say "  extracting $deb"
        dpkg-deb -x "$deb" ./x || { say "  dpkg-deb extraction failed"; exit 1; }
        mkdir -p "$LIB_DIR"
        cp -fL ./x/usr/lib/x86_64-linux-gnu/libvulkan.so.1 "$LIB_DIR/libvulkan.so.1" \
            || { say "  copying libvulkan.so.1 to $LIB_DIR failed"; exit 1; }
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
    work=$(mktemp -d -p "$SERVER_DIR" .ge-tmp-XXXXXX) || { say "ERROR: mktemp failed in $SERVER_DIR"; return 1; }
    say "  working directory: $work"
    (
        cd "$work" || exit 1
        # GE-Proton 11 ships as <tag>-x86_64.tar.gz, older releases as <tag>.tar.gz
        asset=""
        for cand in "$tag-x86_64.tar.gz" "$tag.tar.gz"; do
            say "  downloading $cand (several hundred MB, this can take a while)"
            if curl -fsSL -o "$cand" "$GE_REPO/releases/download/$tag/$cand" 2>/dev/null; then
                asset="$cand"
                break
            fi
            say "  $cand not available"
        done
        [ -n "$asset" ] || { say "  no download found for $tag (tried $tag-x86_64.tar.gz and $tag.tar.gz)"; exit 1; }
        say "  downloaded $asset ($(du -h "$asset" | awk '{print $1}'))"
        # Verify when a checksum file is published; skip with a warning when it is not.
        sumfile="${asset%.tar.gz}.sha512sum"
        say "  fetching checksum $sumfile"
        if curl -fsSL -o "$sumfile" "$GE_REPO/releases/download/$tag/$sumfile" 2>/dev/null; then
            say "  verifying sha512 checksum"
            want=$(awk '{print $1; exit}' "$sumfile")
            got=$(sha512sum "$asset" | awk '{print $1}')
            [ -n "$want" ] && [ "$want" = "$got" ] || { say "  checksum mismatch for $asset"; exit 1; }
            say "  checksum OK"
        else
            say "  no checksum file for $asset, skipping verification"
        fi
        say "  extracting $asset"
        mkdir new && tar -xzf "$asset" -C new --strip-components=1 || { say "  extraction failed"; exit 1; }
        rm -f "$asset"
        [ -f new/proton ] || { say "  extracted archive has no 'proton' script"; exit 1; }
        say "  extraction done"
        # refuse builds whose Wine needs a newer glibc than this image provides
        say "  checking glibc requirement"
        need=$(grep -a -o 'GLIBC_2\.[0-9]\+' new/files/lib/wine/x86_64-unix/ntdll.so 2>/dev/null | sed 's/GLIBC_//' | sort -V | tail -n1)
        have=$(host_glibc)
        say "  $tag needs glibc ${need:-unknown}, image has ${have:-unknown}"
        if [ -n "$need" ] && [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -n1)" != "$have" ]; then
            say "  $tag needs glibc $need, this image has $have. Use a Debian trixie based image."
            exit 7
        fi
        echo "$tag" > new/.ge_tag
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 7 ]; then
            echo "$tag glibc-$(host_glibc)" > "$SERVER_DIR/.ge_rejected"
            say "  remembering that $tag is incompatible so it isn't downloaded again on every start"
        fi
        say "  cleaning up $work"
        rm -rf "$work"
        return 1
    fi
    say "  swapping the new GE-Proton into $GE_DIR"
    rm -rf "$GE_DIR.old"
    [ -d "$GE_DIR" ] && mv "$GE_DIR" "$GE_DIR.old"
    if mv "$work/new" "$GE_DIR"; then
        say "  removing the previous GE-Proton"
        rm -rf "$work" "$GE_DIR.old"
    else
        say "  WARNING: moving the new GE-Proton into place failed, restoring the previous one"
        [ -d "$GE_DIR.old" ] && mv "$GE_DIR.old" "$GE_DIR"
        rm -rf "$work"
        return 1
    fi
}

setup_proton() {
    say "[3/4] setting up GE-Proton"
    local cur="" tag=""
    [ -f "$GE_DIR/.ge_tag" ] && cur=$(cat "$GE_DIR/.ge_tag")
    say "installed GE-Proton: ${cur:-none}"

    if [ "$GE_PROTON_VERSION" = "latest" ]; then
        # with auto-update off, an existing GE-Proton or the one bundled in the image is used as is
        if [ "$GE_PROTON_AUTO_UPDATE" = "1" ] || { [ ! -f "$GE_DIR/proton" ] && ! command -v proton >/dev/null 2>&1; }; then
            if [ "$GE_PROTON_AUTO_UPDATE" = "1" ]; then
                say "auto-update is on, checking GitHub for the latest GE-Proton release"
            else
                say "auto-update is off but no Proton is available, checking GitHub for the latest release"
            fi
            tag=$(latest_tag)
            if [ -n "$tag" ]; then
                say "latest GE-Proton release: $tag"
            else
                say "could not determine the latest GE-Proton (no network?)"
            fi
        else
            say "auto-update is off and a Proton is already available, not checking for updates"
        fi
    else
        tag="$GE_PROTON_VERSION"
        say "GE-Proton version pinned to $tag"
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
    elif [ -n "$tag" ]; then
        say "$tag is already installed, no download needed"
    fi

    if [ -f "$GE_DIR/proton" ]; then
        PROTON_BIN="$GE_DIR/proton"
        say "using GE-Proton from $GE_DIR"
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

say "[4/4] starting the server"
say "Proton: $PROTON_BIN ($( [ -f "$GE_DIR/.ge_tag" ] && cat "$GE_DIR/.ge_tag" || echo image )), glibc $(host_glibc), client path $STEAM_COMPAT_CLIENT_INSTALL_PATH"
say "steamclient.so files (size, date, time, path):"
for f in steamcmd/linux64/steamclient.so .steam/sdk64/steamclient.so .steam/steam/linux64/steamclient.so; do
    if [ -f "$f" ]; then
        say "  $(ls -l --time-style=long-iso "$f" | awk '{print $5, $6, $7, $8}')"
    else
        say "  $f missing"
    fi
done

# GE-Proton 11 needs a display; Xalia (controller helper) is useless on a server
export PROTON_USE_XALIA=0
export WINEDEBUG="${WINEDEBUG:--all}"
RUN_PREFIX=()
if [ "${USE_XVFB:-1}" = "1" ] && command -v xvfb-run >/dev/null 2>&1; then
    RUN_PREFIX=(xvfb-run -a)
    say "running under xvfb-run"
elif [ "${USE_XVFB:-1}" = "1" ]; then
    say "USE_XVFB=1 but xvfb-run is not installed, starting without it"
else
    say "USE_XVFB=0, starting without xvfb-run"
fi

if [ ! -f ./enshrouded_server.exe ]; then
    say "ERROR: enshrouded_server.exe not found in $SERVER_DIR (has the game installed?)"
    exit 1
fi

say "clearing previous log $LOG_FILE"
rm -f "$LOG_FILE"
"${RUN_PREFIX[@]}" "$PROTON_BIN" run ./enshrouded_server.exe &
ENS_PID=$!
say "server launched (pid $ENS_PID)"
say "waiting for Proton/Wine to start and the server to write $LOG_FILE"
say "  this is quiet for a while, especially on the first start while the prefix is created"
tail -c0 -F "$LOG_FILE" --pid=$ENS_PID 2>/dev/null
wait $ENS_PID
rc=$?
say "server process exited with code $rc"
exit $rc