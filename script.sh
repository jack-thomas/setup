#!/bin/sh

set -euo pipefail
# -e          exit on error
# -u          error on undefined variables
# -o pipefail pipeline fails if any command in it fails
#             (without it, ``false | true`` suceeds, for example)
#             (with it,    ``false | true`` fails,   for example, which we want)

# check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root or with sudo."
   exit 1
fi

# check if running on nixos
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Error: This script only supports the NixOS operating system at this time."
    exit 1
else
    . /etc/os-release
    if [[ "$ID" != "nixos" ]]; then
        echo "Error: This script only supports the NixOS operating system at this time."
        exit 1
    fi
fi

# install git, bitwarden-cli, nebula, and supporting dependencies
nix --extra-experimental-features 'nix-command flakes' profile add \
    nixpkgs#bitwarden-cli \
    nixpkgs#git \
    nixpkgs#nebula

# ask for hostname
read -rp "Hostname: " HOSTNAME
git_repo="https://git.withjt.net/devices/${HOSTNAME}.git"

# connect to bitwarden
read -rp "Bitwarden email: " BW_EMAIL # ask for bitwarden email address
read -rsp "Bitwarden master password: " BW_PASSWORD # ask for bitwarden password
bw login "$BW_EMAIL" "$BW_PASSWORD" >/dev/null # log in and unlock the vault
BW_SESSION="$(bw unlock "$BW_PASSWORD" --raw)"
export BW_SESSION
unset BW_PASSWORD # clear the password from the shell variable as soon as possible

# make a plan to clean up
cleanup_bitwarden() {
    bw logout >/dev/null 2>&1 || true
}
trap cleanup_bitwarden EXIT INT TERM

# bitwarden sync
bw sync >/dev/null

# get bitwarden items
BITWARDEN_FOLDER="nebula/hosts/${HOSTNAME}"
BITWARDEN_FOLDERS=$(bw list folders)
BITWARDEN_FOLDER_ID=$(echo "$BITWARDEN_FOLDERS" | jq -r --arg folder "$BITWARDEN_FOLDER" '.[] | select(.name == $folder) | .id')

# get config
NEBULA_CONFIG_YAML=$(
    bw list items |
        jq -er --arg folder_id "$BITWARDEN_FOLDER_ID" '
            .[]
            | select(.folderId == $folder_id and .type == 2 and .name == "config.yaml")
            | .notes // empty
        '
)
if [[ -z "$NEBULA_CONFIG_YAML" ]]; then
    echo "Error: Unable to find config.yaml in Bitwarden folder." >&2
    exit 1
fi

# write to file
printf '%s\n' "$NEBULA_CONFIG_YAML" > "${HOME}/config.yaml"

# connect to nebula
## make a plan to clean up
cleanup() {
    cleanup_bitwarden
    if [[ -n "$NEBULA_PID" ]] && kill -0 "$NEBULA_PID" 2>/dev/null; then
        sudo kill "$NEBULA_PID" 2>/dev/null || true
        wait "$NEBULA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM # this should override the other trap #TODO but test that assumption
## start nebula
sudo nebula -config "${HOME}/config.yaml" &
NEBULA_PID=$!
## wait briefly for nebula to initialize
sleep 2
if ! kill -0 "$NEBULA_PID" 2>/dev/null; then
    # throw an error if nebula fails to start
    echo "Error: Nebula failed to start." >&2
    exit 1
fi

# validate connection to nebula
PING_ERROR=1 # assume an error
for ((ATTEMPT = 1; ATTEMPT <= 12; attempt++)); do
    if ping -c 1 -W 2 git.withjt.net >/dev/null 2>&1; then
        PING_ERROR=0 # no error
        break
    fi
done
if [[ $PING_ERROR -eq 1 ]]; then
    echo "Error: Unable to ping git.withjt.net"
    exit 1
else
    echo "Successfully pinged git.withjt.net"
fi

# validate that the repo exists (indicating that the hostname is valid)
if ! git ls-remote "$REPO_URL" >/dev/null 2>&1; then
    echo "Error: Repository does not exist or is not accessible: $REPO_URL" >&2
    exit 1
fi

# download and execute further instructions
mkdir -p "${HOME}/git"
git -C "${HOME}/git" clone "${git_repo}"
sh "${HOME}/git/${HOSTNAME}/install.sh"
