#!/bin/bash

set -e

echo "========================================="
echo "Starting ARK Server"
echo "========================================="

SERVER_DIR="/home/container/ShooterGame/Binaries/Linux"

if [ ! -d "${SERVER_DIR}" ]; then
    echo "ERROR: Server directory does not exist:"
    echo "${SERVER_DIR}"
    exit 1
fi

cd "${SERVER_DIR}"

SERVER_ARGS="${SERVER_MAP}?listen"
SERVER_ARGS="${SERVER_ARGS}?SessionName=${SESSION_NAME}"
SERVER_ARGS="${SERVER_ARGS}?ServerPassword=${ARK_PASSWORD}"
SERVER_ARGS="${SERVER_ARGS}?ServerAdminPassword=${ARK_ADMIN_PASSWORD}"
SERVER_ARGS="${SERVER_ARGS}?Port=${SERVER_PORT}"
SERVER_ARGS="${SERVER_ARGS}?QueryPort=${QUERY_PORT}"
SERVER_ARGS="${SERVER_ARGS}?MaxPlayers=${MAX_PLAYERS}"

if [ -n "${RCON_PORT}" ]; then
    SERVER_ARGS="${SERVER_ARGS}?RCONPort=${RCON_PORT}"
    SERVER_ARGS="${SERVER_ARGS}?RCONEnabled=True"
fi

if [ -n "${MOD_ID}" ]; then
    SERVER_ARGS="${SERVER_ARGS}?GameModIds=${MOD_ID}"
fi

EXTRA_ARGS=(
    -server
    -log
)

if [ "${BATTLE_EYE}" != "1" ]; then
    EXTRA_ARGS+=("-NoBattlEye")
fi

if [ -n "${MOD_ID}" ]; then
    EXTRA_ARGS+=("-automanagedmods")
fi

echo ""
echo "Launch Command:"
echo "./ShooterGameServer ${SERVER_ARGS} ${EXTRA_ARGS[*]} ${ARGS}"
echo ""

exec ./ShooterGameServer \
    "${SERVER_ARGS}" \
    "${EXTRA_ARGS[@]}" \
    ${ARGS}