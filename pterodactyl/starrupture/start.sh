#!/bin/bash

# Prints a simple banner for each step, with a short pause so the
# console output is easy to follow.
step() {
    sleep 2
    echo ""
    echo "========================================="
    echo "  $1"
    echo "========================================="
    sleep 1
}

step "Installing required packages"
# Install required packages (jq, unzip, curl). Pterodactyl containers may run
# unprivileged, so tolerate failure - fallbacks below handle a missing jq.
if apt-get update -qq 2>/dev/null && apt-get install -y -qq jq unzip curl ca-certificates 2>/dev/null; then
    echo "  - Packages installed."
else
    echo "  - apt-get failed (likely no root in container), continuing with fallbacks."
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
                        if ! command -v unzip &>/dev/null; then
                            echo "unzip not found, cannot extract ModLoader update. Skipping."
                        else
                            unzip -o -q "${TMP_ZIP}" -d "/home/container/StarRupture/Binaries/Win64"
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

step "Pre-initialising Proton prefix"
echo "This may take 3-5 minutes..."
WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" ${LAUNCHER} wineboot --init 2>&1
echo "Proton prefix ready."

export WINEDLLOVERRIDES
step "Launching server"
echo "  LAUNCHER:          ${LAUNCHER}"
echo "  SERVER_PORT:       ${SERVER_PORT}"
echo "  RCON_PORT:         ${RCON_PORT}"
echo "  SESSION_NAME:      ${SESSION_NAME}"
echo "  SAVE_INTERVAL:     ${SAVE_INTERVAL}"
echo "  WINEDLLOVERRIDES:  ${WINEDLLOVERRIDES}"
echo "-----------------------------------------"
WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" ${LAUNCHER} /home/container/StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe \
    -Log \
    -Port=${SERVER_PORT} \
    -RconPort=${RCON_PORT} \
    -RconPassword="${RCON_PASSWORD}" \
    -SessionName="${SESSION_NAME}" \
    -SaveGameInterval=${SAVE_INTERVAL} 2>&1 &
SR_PID=$!
echo "Server started with PID ${SR_PID}, waiting for log file..."
# Wait for the log file to appear (up to 5 minutes)
LOG_FILE="/home/container/StarRupture/Saved/Logs/StarRupture.log"
WAIT=0
echo "Waiting for log file..."
until [[ -f "${LOG_FILE}" ]] || [[ ${WAIT} -ge 300 ]]; do
    sleep 1
    WAIT=$((WAIT + 1))
done
if [[ -f "${LOG_FILE}" ]]; then
    echo "Log file found, tailing..."
    tail -c0 -F "${LOG_FILE}" --pid=$SR_PID \
        | grep -v -E "LogCore: Warning|LogUObjectBase: Error"
else
    echo "Log file never appeared after 300s, falling back to waiting on process..."
fi
wait ${SR_PID}
echo "Server process exited."
