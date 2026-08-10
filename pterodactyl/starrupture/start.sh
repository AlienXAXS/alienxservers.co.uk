#!/bin/bash

# Prints a simple banner for each step, with a short pause so the
# console output is easy to follow.
step() {
    echo ""
    echo "========================================="
    echo "  $1"
    echo "========================================="
    sleep 1
}

# Dumps the current process tree with kernel wait-channel and state columns.
# Used whenever something looks hung - the STAT and WCHAN columns tell us
# whether a process is running, sleeping on the network, stopped, or a zombie.
dump_state() {
    echo "----- process state ($(date -u '+%H:%M:%S') UTC) -----"
    # 'time' is accumulated CPU time: a hung process showing 00:00:00 is
    # blocked on something, one climbing steadily is spinning in a loop.
    if command -v ps &>/dev/null; then
        ps -eo pid,ppid,stat,etime,time,wchan:22,args 2>/dev/null \
            || ps -eo pid,ppid,stat,etime,time,args 2>/dev/null \
            || ps aux
    else
        # Minimal images sometimes ship no ps at all - read /proc directly.
        for p in /proc/[0-9]*; do
            [[ -r "${p}/stat" ]] || continue
            printf '%-8s %-8s %s\n' \
                "${p##*/}" \
                "$(cat "${p}/wchan" 2>/dev/null)" \
                "$(tr '\0' ' ' < "${p}/cmdline" 2>/dev/null)"
        done
    fi
    echo "-------------------------------------------"
}

# Kills any wine/proton processes left behind by a previous attempt. A stuck
# wineserver will make every later launch hang, so this runs before retries.
kill_wine() {
    if command -v pkill &>/dev/null; then
        pkill -9 -f 'wineserver|wine64|wine-preloader|services.exe' 2>/dev/null
    else
        for p in /proc/[0-9]*; do
            [[ -r "${p}/cmdline" ]] || continue
            case "$(tr '\0' ' ' < "${p}/cmdline" 2>/dev/null)" in
                *wineserver*|*wine-preloader*|*services.exe*)
                    kill -9 "${p##*/}" 2>/dev/null ;;
            esac
        done
    fi
    sleep 2
}

echo "Starting server, please wait..."
step "Checking required tools"
# The container runs unprivileged (no apt), so fetch static binaries into
# /home/container for anything the image doesn't ship. jq is handled in its
# own step below; busybox provides unzip.
UNZIP_CMD="unzip"
if ! command -v unzip &>/dev/null; then
    if [[ ! -x /home/container/busybox ]]; then
        echo "unzip not found in image, downloading static busybox..."
        curl -fsSL -o /home/container/busybox "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
        chmod +x /home/container/busybox 2>/dev/null
    fi
    if [[ -x /home/container/busybox ]]; then
        UNZIP_CMD="/home/container/busybox unzip"
        echo "Using busybox unzip."
    else
        echo "Warning: could not obtain busybox, ModLoader updates will be skipped if unzip is needed."
        UNZIP_CMD=""
    fi
else
    echo "unzip found in image."
fi

SAVE_DIR="/home/container/StarRupture/Saved/SaveGames/${SESSION_NAME}"

step "Cleaning up Steam leftovers"
if [[ -d "/home/container/steamapps" ]]; then
    echo "Cleaning up existing Steamapps folder"
    rm -rf /home/container/steamapps
    echo "  - Done"
fi

step "Checking save files"
if [[ -d "${SAVE_DIR}" ]]; then
    echo "Existing save directory detected: ${SAVE_DIR}"
    echo "Checking required save files..."

    if [[ ! -f "${SAVE_DIR}/AutoSave0.met" ]] || [[ ! -f "${SAVE_DIR}/AutoSave0.sav" ]]; then
    	clear
	    echo "#"
	    echo "#"
		echo -e " /######## /#######  /#######   /######  /####### "
		echo -e "| ##_____/| ##__  ##| ##__  ## /##__  ##| ##__  ##"
		echo -e "| ##      | ##  \ ##| ##  \ ##| ##  \ ##| ##  \ ##"
		echo -e "| #####   | #######/| #######/| ##  | ##| #######/"
		echo -e "| ##__/   | ##__  ##| ##__  ##| ##  | ##| ##__  ##"
		echo -e "| ##      | ##  \ ##| ##  \ ##| ##  | ##| ##  \ ##"
		echo -e "| ########| ##  | ##| ##  | ##|  ######/| ##  | ##"
		echo -e "|________/|__/  |__/|__/  |__/ \______/ |__/  |__/"
    	echo "#"
    	echo "#"
                                                  
                                                  
        echo "Save directory exists, but required save files are missing."
        echo "Expected files:"
        echo "  ${SAVE_DIR}/AutoSave0.met"
        echo "  ${SAVE_DIR}/AutoSave0.sav"
        echo "The server will not be started."
        echo "If this is an existing world, the file names must be exactly:"
        echo "  AutoSave0.met"
        echo "  AutoSave0.sav"
        exit 1
    fi

    echo "Required save files found."
else
    echo "No existing save directory found for session '${SESSION_NAME}', continuing normally."
fi

step "Generating DSSettings.txt"
SETTINGS_FILE="/home/container/DSSettings.txt"

if [[ -f "${SAVE_DIR}/AutoSave0.sav" ]]; then
    START_GAME="false"
    LOAD_GAME="true"
    echo "Existing AutoSave0.sav detected, server will load saved game."
else
    START_GAME="true"
    LOAD_GAME="false"
    echo "No AutoSave0.sav detected, server will start a new game."
fi

cat > "${SETTINGS_FILE}" <<EOF
{
    "SessionName": "${SESSION_NAME}",
    "SaveGameInterval": "${SAVE_INTERVAL}",
    "StartNewGame": "${START_GAME}",
    "LoadSavedGame": "${LOAD_GAME}",
    "SaveGameName": "AutoSave0.sav"
}
EOF

echo "DSSettings.txt created at ${SETTINGS_FILE}"
echo "Contents:"
cat "${SETTINGS_FILE}"

step "Configuring RCON"
# If no RCON password is set, generate a random one so RCON always works
if [[ -z "${RCON_PASSWORD}" ]]; then
    RCON_PASSWORD=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 24)
    echo "No RCON password set, generated random password: ${RCON_PASSWORD}"
fi

step "Checking jq"
## Ensure jq is available (prefer the apt-installed one)
if command -v jq &>/dev/null && [[ ! -f /home/container/jq ]]; then
    echo "Using system jq: $(command -v jq)"
    ln -sf "$(command -v jq)" /home/container/jq
fi
if [[ ! -f /home/container/jq ]]; then
    echo "Downloading jq..."
    curl -Lo /home/container/jq https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64
    chmod +x /home/container/jq
    echo "jq downloaded successfully"
else
    echo "jq already exists, skipping download"
fi

# --- ModLoader update check ---
step "Checking for ModLoader updates"
UPDATE_STATE_FILE=""
if [[ -f "/home/container/StarRupture/Binaries/Win64/update_state.ini" ]]; then
    UPDATE_STATE_FILE="/home/container/StarRupture/Binaries/Win64/update_state.ini"
elif [[ -f "/home/container/StarRupture/Binaries/Win64/ModLoader/update_state.ini" ]]; then
    UPDATE_STATE_FILE="/home/container/StarRupture/Binaries/Win64/ModLoader/update_state.ini"
fi

if [[ -n "${UPDATE_STATE_FILE}" ]]; then
    echo "Found update_state.ini at ${UPDATE_STATE_FILE}"

    CURRENT_BUILD_TAG=$(grep -i "^BuildTag" "${UPDATE_STATE_FILE}" | head -n1 | cut -d'=' -f2- | tr -d '[:space:]"')
    echo "Current BuildTag: ${CURRENT_BUILD_TAG}"

    echo "Fetching latest release info from GitHub API..."
    RELEASE_API_JSON=$(curl -s -L \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/AlienXAXS/StarRupture-ModLoader/releases/latest")

    # Sanity check: did we actually get a release object back?
    RELEASE_TAG_NAME=$(echo "${RELEASE_API_JSON}" | /home/container/jq -r '.tag_name // empty')

    if [[ -z "${RELEASE_TAG_NAME}" ]]; then
        echo "Warning: GitHub API did not return a valid release (rate limited, network issue, or repo/API problem). Skipping ModLoader update check."
        echo "Raw API response (truncated): $(echo "${RELEASE_API_JSON}" | head -c 300)"
    else
        echo "Latest release tag: ${RELEASE_TAG_NAME}"

        MANIFEST_URL=$(echo "${RELEASE_API_JSON}" | /home/container/jq -r '.assets[] | select(.name | test("manifest-server\\.json$"; "i")) | .browser_download_url' | head -n1)

        if [[ -z "${MANIFEST_URL}" ]] || [[ "${MANIFEST_URL}" == "null" ]]; then
            echo "Warning: no manifest-server.json asset found on release ${RELEASE_TAG_NAME}, skipping update check."
        else
            echo "Fetching manifest from ${MANIFEST_URL}..."
            MANIFEST_JSON=$(curl -s -L "${MANIFEST_URL}")
            LATEST_BUILD_TAG=$(echo "${MANIFEST_JSON}" | /home/container/jq -r '.build_tag // empty')
            echo "Latest manifest build_tag: ${LATEST_BUILD_TAG}"

            if [[ -n "${LATEST_BUILD_TAG}" ]] && [[ "${CURRENT_BUILD_TAG}" != "${LATEST_BUILD_TAG}" ]]; then
                echo "BuildTag mismatch (installed: ${CURRENT_BUILD_TAG:-none} / latest: ${LATEST_BUILD_TAG}). Updating ModLoader..."

                ASSET_URL=$(echo "${RELEASE_API_JSON}" | /home/container/jq -r '.assets[] | select(.name | test("Server.*\\.zip$"; "i")) | .browser_download_url' | head -n1)
                ASSET_NAME=$(echo "${RELEASE_API_JSON}" | /home/container/jq -r '.assets[] | select(.name | test("Server.*\\.zip$"; "i")) | .name' | head -n1)

                if [[ -n "${ASSET_URL}" ]] && [[ "${ASSET_URL}" != "null" ]]; then
                    echo "Downloading ${ASSET_NAME} from ${ASSET_URL}..."
                    TMP_ZIP="/tmp/${ASSET_NAME}"
                    curl -sL -o "${TMP_ZIP}" "${ASSET_URL}"

                    if [[ -f "${TMP_ZIP}" ]]; then
                        echo "Extracting to /home/container/StarRupture/Binaries/Win64 ..."
                        if [[ -z "${UNZIP_CMD}" ]]; then
                            echo "unzip not available, cannot extract ModLoader update. Skipping."
                        else
                            ${UNZIP_CMD} -o -q "${TMP_ZIP}" -d "/home/container/StarRupture/Binaries/Win64"
                            echo "ModLoader update extracted."
                        fi
                        rm -f "${TMP_ZIP}"
                    else
                        echo "Warning: ModLoader Server asset failed to download, skipping update."
                    fi
                else
                    echo "Warning: could not locate a Server .zip asset on release ${RELEASE_TAG_NAME}, skipping update."
                fi
            else
                echo "ModLoader is up to date, no action needed."
            fi
        fi
    fi
else
    echo "update_state.ini not found in either expected location, skipping ModLoader update check."
fi
step "Generating password files"
## Generate password files if passwords are set
if [[ -n "${ADMIN_PASSWORD}" ]] || [[ -n "${PLAYER_PASSWORD}" ]]; then
    echo "At least one password is set, checking for existing files..."

    if [[ ! -f /home/container/Password.json ]] || [[ ! -f /home/container/PlayerPassword.json ]]; then
        echo "One or more password files missing, generating..."
        RESPONSE=$(curl -s --request POST \
            --url https://starrupture-utilities.com/passwords/ \
            --header 'Content-Type: multipart/form-data' \
            --form "adminpassword=${ADMIN_PASSWORD}" \
            --form "playerpassword=${PLAYER_PASSWORD}")

        echo "API response received, length: ${#RESPONSE} chars"
        echo "API response: ${RESPONSE}"

        if [[ -n "${RESPONSE}" ]]; then
            if [[ -n "${ADMIN_PASSWORD}" ]] && [[ ! -f /home/container/Password.json ]]; then
                echo "Generating Password.json..."
                ADMIN_HASH=$(echo "${RESPONSE}" | /home/container/jq -r '.adminpassword')
                echo "Extracted adminpassword, length: ${#ADMIN_HASH} chars"
                if [[ -n "${ADMIN_HASH}" ]] && [[ "${ADMIN_HASH}" != "null" ]]; then
                    echo "${RESPONSE}" | /home/container/jq '{password: .adminpassword}' > /home/container/Password.json
                    echo "Password.json created, size: $(wc -c < /home/container/Password.json) bytes"
                else
                    echo "Warning: adminpassword was empty or null in API response, skipping Password.json"
                fi
            fi

            if [[ -n "${PLAYER_PASSWORD}" ]] && [[ ! -f /home/container/PlayerPassword.json ]]; then
                echo "Generating PlayerPassword.json..."
                PLAYER_HASH=$(echo "${RESPONSE}" | /home/container/jq -r '.playerpassword')
                echo "Extracted playerpassword, length: ${#PLAYER_HASH} chars"
                if [[ -n "${PLAYER_HASH}" ]] && [[ "${PLAYER_HASH}" != "null" ]]; then
                    echo "${RESPONSE}" | /home/container/jq '{password: .playerpassword}' > /home/container/PlayerPassword.json
                    echo "PlayerPassword.json created, size: $(wc -c < /home/container/PlayerPassword.json) bytes"
                else
                    echo "Warning: playerpassword was empty or null in API response, skipping PlayerPassword.json"
                fi
            fi
        else
            echo "Warning: API response was empty, cannot generate password files"
        fi
    else
        echo "Both password files already exist, skipping generation"
    fi
else
    echo "No passwords set, skipping password file generation"
fi

# Graceful shutdown handler - sends RCON exit command before killing the server
SR_PID=""
_shutdown() {
    # If the server hasn't been launched yet (e.g. signal during wineboot
    # pre-init), there is nothing to shut down gracefully - just exit.
    if [[ -z "${SR_PID}" ]]; then
        echo "Shutdown signal received before server launch, exiting."
        exit 0
    fi
    echo "Shutdown signal received, sending RCON exit command..."
    /home/container/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASSWORD}" "exit" 2>/dev/null
    # Wait up to 15 seconds for the server to exit gracefully
    WAIT=0
    while kill -0 "${SR_PID}" 2>/dev/null; do
        if [[ ${WAIT} -ge 15 ]]; then
            echo "Server did not exit after 15s, force killing..."
            kill "${SR_PID}" 2>/dev/null
            break
        fi
        sleep 1
        WAIT=$((WAIT + 1))
        echo "Waiting for server to exit... ${WAIT}s"
    done
    if ! kill -0 "${SR_PID}" 2>/dev/null; then
        echo "Server gracefully shut down."
    fi
}
trap '_shutdown' SIGINT SIGTERM
# Set WINEDLLOVERRIDES, falling back to a sensible default if not set
if [[ -z "${WINEDLLOVERRIDES}" ]]; then
    WINEDLLOVERRIDES="mscoree,mshtml="
    echo "No WINEDLLOVERRIDES set, using default: ${WINEDLLOVERRIDES}"
fi

step "Checking ModLoader"
# The ModLoader ships as a dwmapi.dll proxy next to the server exe, so it is
# loaded by the Windows loader before any Unreal code runs. That makes it the
# first thing to rule out when the server starts but never writes a log line.
# Set DISABLE_MODLOADER=1 to move the DLL aside and boot vanilla.
MODLOADER_DLL="/home/container/StarRupture/Binaries/Win64/dwmapi.dll"

# Removes any dwmapi entry from a WINEDLLOVERRIDES string. Entries are
# semicolon separated ("mscoree,mshtml=;dwmapi=n,b") and the key list is
# everything left of the '='.
strip_dwmapi_override() {
    local out="" entry
    local IFS=';'
    for entry in $1; do
        [[ -z "${entry}" ]] && continue
        case "${entry%%=*}" in
            *dwmapi*) continue ;;
        esac
        out="${out:+${out};}${entry}"
    done
    printf '%s' "${out}"
}

if [[ "${DISABLE_MODLOADER,,}" =~ ^(1|true|yes)$ ]]; then
    echo "DISABLE_MODLOADER is set - starting VANILLA (no mods will load)."
    if [[ -f "${MODLOADER_DLL}" ]]; then
        mv -f "${MODLOADER_DLL}" "${MODLOADER_DLL}.disabled"
        echo "  - Moved dwmapi.dll aside to dwmapi.dll.disabled"
    else
        echo "  - No dwmapi.dll present, nothing to move."
    fi
    WINEDLLOVERRIDES="$(strip_dwmapi_override "${WINEDLLOVERRIDES}")"
    echo "  - WINEDLLOVERRIDES is now: ${WINEDLLOVERRIDES:-<empty>}"
else
    # Restore a previously disabled DLL so unsetting the variable is enough
    # to get the ModLoader back.
    if [[ -f "${MODLOADER_DLL}.disabled" ]] && [[ ! -f "${MODLOADER_DLL}" ]]; then
        mv -f "${MODLOADER_DLL}.disabled" "${MODLOADER_DLL}"
        echo "ModLoader was previously disabled, dwmapi.dll restored."
    fi

    if [[ -f "${MODLOADER_DLL}" ]]; then
        echo "ModLoader present: $(ls -la "${MODLOADER_DLL}" | awk '{print $5" bytes, "$6" "$7" "$8}')"
        # Without a native override wine loads its own builtin dwmapi and the
        # proxy is silently ignored - the server boots with no mods at all.
        if [[ ";${WINEDLLOVERRIDES};" != *"dwmapi"* ]]; then
            echo "WARNING: WINEDLLOVERRIDES does not mention dwmapi."
            echo "         Wine will load its builtin dwmapi and the ModLoader will NOT load."
            echo "         Add 'dwmapi=n,b' to the WINEDLLOVERRIDES startup variable if mods are wanted."
        fi
    else
        echo "No dwmapi.dll found, server will run without the ModLoader."
    fi
fi

step "Configuring Proton data directory"
# Everything Proton/Wine writes is forced under /home/container/.proton so it is
# visible over SFTP/the file manager. If the prefix goes bad (symptom: proton
# launches, prints "fsync: up and running" and then hangs forever), delete
# /home/container/.proton and restart - it will be rebuilt from scratch.
PROTON_DATA_DIR="/home/container/.proton"

# Optional escape hatch: set WIPE_PROTON_PREFIX to 1/true/yes to nuke the
# prefix on the next boot without needing file access.
if [[ "${WIPE_PROTON_PREFIX,,}" =~ ^(1|true|yes)$ ]]; then
    echo "WIPE_PROTON_PREFIX is set, removing ${PROTON_DATA_DIR}..."
    rm -rf "${PROTON_DATA_DIR}"
    echo "  - Done, prefix will be rebuilt."
fi

mkdir -p "${PROTON_DATA_DIR}/compatdata" \
         "${PROTON_DATA_DIR}/steam" \
         "${PROTON_DATA_DIR}/cache" \
         "${PROTON_DATA_DIR}/xdg/data" \
         "${PROTON_DATA_DIR}/xdg/config" \
         "${PROTON_DATA_DIR}/xdg/cache"

# Proton itself: compatdata holds the wine prefix (compatdata/pfx)
export STEAM_COMPAT_DATA_PATH="${PROTON_DATA_DIR}/compatdata"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="${PROTON_DATA_DIR}/steam"
export WINEPREFIX="${STEAM_COMPAT_DATA_PATH}/pfx"

# protonfixes / umu / wine all follow the XDG dirs for their state and caches,
# which otherwise scatter across ~/.local, ~/.config and ~/.cache.
export XDG_DATA_HOME="${PROTON_DATA_DIR}/xdg/data"
export XDG_CONFIG_HOME="${PROTON_DATA_DIR}/xdg/config"
export XDG_CACHE_HOME="${PROTON_DATA_DIR}/xdg/cache"

# Shader caches (harmless on a headless server, but keeps them out of $HOME)
export DXVK_STATE_CACHE_PATH="${PROTON_DATA_DIR}/cache"
export __GL_SHADER_DISK_CACHE_PATH="${PROTON_DATA_DIR}/cache"
export MESA_SHADER_CACHE_DIR="${PROTON_DATA_DIR}/cache"

echo "Proton data directory: ${PROTON_DATA_DIR}"
echo "  STEAM_COMPAT_DATA_PATH:           ${STEAM_COMPAT_DATA_PATH}"
echo "  STEAM_COMPAT_CLIENT_INSTALL_PATH: ${STEAM_COMPAT_CLIENT_INSTALL_PATH}"
echo "  WINEPREFIX:                       ${WINEPREFIX}"
if [[ -d "${WINEPREFIX}" ]]; then
    echo "Existing Proton prefix found, reusing it."
else
    echo "No Proton prefix yet, a fresh one will be created."
fi

step "Pre-initialising Proton prefix"
echo "This may take 3-5 minutes..."

# wineboot has no business taking longer than this. If it does, the prefix
# creation has deadlocked (usually a stuck wineserver or services.exe) - kill
# the leftovers and try once more rather than hanging the container forever.
WINEBOOT_TIMEOUT="${WINEBOOT_TIMEOUT:-600}"
WINEBOOT_OK="false"
for ATTEMPT in 1 2; do
    echo "wineboot attempt ${ATTEMPT}/2 (timeout ${WINEBOOT_TIMEOUT}s), started $(date -u '+%H:%M:%S') UTC"
    if command -v timeout &>/dev/null; then
        WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" \
            timeout --signal=KILL "${WINEBOOT_TIMEOUT}" ${LAUNCHER} wineboot --init 2>&1
        RC=$?
    else
        echo "Note: 'timeout' not available in image, running without a time limit."
        WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" ${LAUNCHER} wineboot --init 2>&1
        RC=$?
    fi

    if [[ ${RC} -eq 137 ]] || [[ ${RC} -eq 124 ]]; then
        echo "!!! wineboot did NOT finish within ${WINEBOOT_TIMEOUT}s - the prefix init is hung."
        dump_state
        echo "Killing leftover wine processes before retrying..."
        kill_wine
        continue
    fi

    echo "wineboot exited with code ${RC} after $(date -u '+%H:%M:%S') UTC"
    WINEBOOT_OK="true"
    break
done

if [[ "${WINEBOOT_OK}" != "true" ]]; then
    echo "Proton prefix could not be initialised after 2 attempts."
    echo "Delete /home/container/.proton (or set WIPE_PROTON_PREFIX=1) and try again."
    echo "If it keeps happening, the container is likely unable to complete wine's"
    echo "first-run setup - the process dumps above show where it stalled."
    exit 1
fi
echo "Proton prefix ready."

export WINEDLLOVERRIDES

# --- Debug mode -------------------------------------------------------------
# Set PROTON_DEBUG=1 as a startup variable to capture why the server never
# reaches its first log line. Adds a full wine trace under
# /home/container/.proton/logs and forces Unreal to log to stdout, so output
# appears in the console even when Saved/Logs is never written.
DEBUG_ARGS=()
export PROTON_LOG_DIR="${PROTON_DATA_DIR}/logs"
mkdir -p "${PROTON_LOG_DIR}"
if [[ "${PROTON_DEBUG,,}" =~ ^(1|true|yes)$ ]]; then
    echo "PROTON_DEBUG enabled - verbose wine logging is ON (slower startup)."
    export PROTON_LOG=1
    # +loaddll shows every DLL wine resolves, which is how a missing or broken
    # dependency shows up. Deliberately NOT +relay - that is unusably slow.
    export WINEDEBUG="${WINEDEBUG:-+loaddll,+seh,+tid,+msgbox}"
    # -unattended stops Unreal blocking on any modal dialog, -stdout sends the
    # log to the console instead of only to Saved/Logs.
    DEBUG_ARGS=(-unattended -nosplash -stdout -FullStdOutLogOutput)
    echo "  PROTON_LOG_DIR: ${PROTON_LOG_DIR}"
    echo "  WINEDEBUG:      ${WINEDEBUG}"
    echo "  Extra args:     ${DEBUG_ARGS[*]}"
fi

step "Launching server"
echo "  LAUNCHER:          ${LAUNCHER}"
echo "  SERVER_PORT:       ${SERVER_PORT}"
echo "  RCON_PORT:         ${RCON_PORT}"
echo "  SESSION_NAME:      ${SESSION_NAME}"
echo "  SAVE_INTERVAL:     ${SAVE_INTERVAL}"
echo "  WINEDLLOVERRIDES:  ${WINEDLLOVERRIDES}"
echo "  PROTON_DATA_DIR:   ${PROTON_DATA_DIR}"

SERVER_EXE="/home/container/StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe"
if [[ ! -f "${SERVER_EXE}" ]]; then
    echo "FATAL: server executable not found at ${SERVER_EXE}"
    echo "Contents of Binaries/Win64:"
    ls -la /home/container/StarRupture/Binaries/Win64 2>&1 | head -40
    exit 1
fi
echo "  SERVER_EXE:        ${SERVER_EXE} ($(stat -c %s "${SERVER_EXE}" 2>/dev/null) bytes)"
echo "-----------------------------------------"

# Keep a copy of everything the launcher prints. Proton/wine errors often
# arrive in a burst right before an early exit and scroll past in the console.
LAUNCH_LOG="${PROTON_DATA_DIR}/logs/launch-output.log"
: > "${LAUNCH_LOG}"

WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" ${LAUNCHER} "${SERVER_EXE}" \
    -Log \
    -Port=${SERVER_PORT} \
    -RconPort=${RCON_PORT} \
    -RconPassword="${RCON_PASSWORD}" \
    -SessionName="${SESSION_NAME}" \
    -SaveGameInterval=${SAVE_INTERVAL} "${DEBUG_ARGS[@]}" \
    > >(tee -a "${LAUNCH_LOG}") 2>&1 &
SR_PID=$!
echo "Server started with PID ${SR_PID}, waiting for log file..."
# Wait for the log file to appear (up to 5 minutes)
LOG_FILE="/home/container/StarRupture/Saved/Logs/StarRupture.log"
WAIT=0
echo "Waiting for log file..."
EXITED_EARLY="false"
until [[ -f "${LOG_FILE}" ]] || [[ ${WAIT} -ge 300 ]]; do
    # If proton exited on its own there is no point waiting out the full 300s.
    if ! kill -0 "${SR_PID}" 2>/dev/null; then
        echo "Launcher process exited after ${WAIT}s without producing a log file."
        EXITED_EARLY="true"
        break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
    # Heartbeat so a hang is obvious in the console, with a process dump at
    # 60s and 180s showing exactly what the server is blocked on.
    if (( WAIT % 30 == 0 )); then
        echo "  ...still waiting for ${LOG_FILE} (${WAIT}s elapsed)"
    fi
    if (( WAIT == 60 || WAIT == 180 )); then
        echo "No log file after ${WAIT}s - dumping process state:"
        dump_state
        echo "Contents of Saved/Logs:"
        ls -la /home/container/StarRupture/Saved/Logs 2>&1 | head -20
    fi
done
if [[ -f "${LOG_FILE}" ]]; then
    echo "Log file found, tailing..."
    tail -c0 -F "${LOG_FILE}" --pid=$SR_PID \
        | grep -v -E "LogCore: Warning|LogUObjectBase: Error"
elif [[ "${EXITED_EARLY}" == "true" ]]; then
    echo "Launcher already exited, collecting exit status..."
else
    echo "Log file never appeared after 300s, falling back to waiting on process..."
fi
wait ${SR_PID}
SR_RC=$?

echo ""
echo "========================================="
echo "  Server process exited with code ${SR_RC}"
echo "========================================="
# Exit codes above 128 are "killed by signal N" where N = code - 128.
if (( SR_RC > 128 )); then
    SIG=$(( SR_RC - 128 ))
    echo "That is signal ${SIG}$(kill -l "${SIG}" 2>/dev/null | sed 's/^/ (SIG/;s/$/)/')"
    case ${SIG} in
        9)  echo "SIGKILL - almost always the container running out of memory."
            echo "Check the server's memory limit; Unreal dedicated servers are hungry." ;;
        11) echo "SIGSEGV - the process crashed." ;;
        6)  echo "SIGABRT - the process aborted (assertion or unhandled exception)." ;;
        15) echo "SIGTERM - something asked it to stop." ;;
    esac
fi

if [[ ! -f "${LOG_FILE}" ]]; then
    echo ""
    echo "No Unreal log was ever written. Captured launcher output was:"
    echo "-----------------------------------------"
    if [[ -s "${LAUNCH_LOG}" ]]; then
        tail -n 60 "${LAUNCH_LOG}"
    else
        echo "(the launcher produced no output at all)"
    fi
    echo "-----------------------------------------"
    echo "Saved directory contents:"
    ls -la /home/container/StarRupture/Saved 2>&1 | head -20
    if [[ -d "${PROTON_LOG_DIR}" ]]; then
        echo "Proton logs in ${PROTON_LOG_DIR}:"
        ls -la "${PROTON_LOG_DIR}" 2>&1 | head -20
    fi
fi
