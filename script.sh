#!/bin/sh

set -euo pipefail
# -e          exit on error
# -u          error on undefined variables
# -o pipefail pipeline fails if any command in it fails
#             (without it, ``false | true`` suceeds, for example)
#             (with it,    ``false | true`` fails,   for example, which we want)

# check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root or with sudo. Try this:"
   echo "curl -ssL https://raw.githubusercontent.com/jack-thomas/setup/refs/heads/master/script.sh | sudo sh"
   exit 1
fi

# determine operating system
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Running on macOS."
    OS_CLASS="macos"
elif [[ -f /etc/os-release ]]; then
    OS_CLASS="linux"
    . /etc/os-release
    case "$ID" in
        almalinux)
            echo "Running on Alma Linux."
            OS_DISTRO="alma"
            ;;
        arch)
            echo "Running on Arch Linux."
            OS_DISTRO="arch"
            ;;
        nixos)
            echo "Running on NixOS."
            OS_DISTRO="nixos"
            ;;
        ubuntu)
            echo "Running on Ubuntu."
            OS_DISTRO="ubuntu"
            ;;
        *)
            echo "Error: Unsupported operating system: ${PRETTY_NAME:-$ID}." >&2
            exit 1
            ;;
    esac
else
    echo "Error: Unable to determine operating system." >&2
    exit 1
fi

# sample operating system-based tree (for later)
#
# if [[ "${OS_CLASS}" == "macos" ]]; then
# elif [[ "${OS_CLASS}" == "linux" ]]; then
#     if [[ "${OS_DISTRO}" == "alma" ]]; then
#     elif [[ "${OS_DISTRO}" == "arch" ]]; then
#     elif [[ "${OS_DISTRO}" == "nixos" ]]; then
#     elif [[ "${OS_DISTRO}" == "ubuntu" ]]; then
#     fi
# else
#     echo "Error: Unsupported operating system."
#     exit 1
# fi

# install git, bitwarden-cli, nebula, and supporting dependencies
if [[ "${OS_CLASS}" == "macos" ]]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" # install homebrew
    brew install \
        git \
        bitwarden-cli \
        nebula
elif [[ "${OS_CLASS}" == "linux" ]]; then
    if [[ "${OS_DISTRO}" == "alma" ]]; then
        # upgrade first
        sudo dnf upgrade --refresh
        # install git
        sudo dnf install -y git
        # install bitwaden cli
        sudo dnf install -y nodejs npm gcc-c++ make
        sudo npm install -g @bitwarden/cli
        # install nebula manually
        mkdir -p "${HOME}/downloads"
        wget -P "${HOME}/downloads" https://github.com/slackhq/nebula/releases/download/v1.11.0/nebula-linux-amd64.tar.gz #TODO automate this to ensure that it downloads the latest version
        tar xzf nebula-linux-amd64.tar.gz -C "${HOME}/downloads/nebula-linux-amd64"
        sudo mv "${HOME}/downloads/nebula-linux-amd64/nebula" /usr/bin/nebula
        sudo mv "${HOME}/downloads/nebula-linux-amd64/nebula-cert" /usr/bin/nebula-cert
        sudo chown root:root /usr/bin/nebula
        sudo chown root:root /usr/bin/nebula-cert
        sudo restorecon -v /usr/bin/nebula
        sudo restorecon -v /usr/bin/nebula-cert
    elif [[ "${OS_DISTRO}" == "arch" ]]; then
        sudo pacman -Sy --noconfirm
        sudo pacman -S --needed \
            base-devel \
            bitwarden-cli \
            curl \
            git \
            nebula
    elif [[ "${OS_DISTRO}" == "nixos" ]]; then
        nix --extra-experimental-features 'nix-command flakes' profile add \
            nixpkgs#bitwarden-cli \
            nixpkgs#git \
            nixpkgs#nebula
    elif [[ "${OS_DISTRO}" == "ubuntu" ]]; then
        echo "#TODO install git"
        echo "#TODO install bitwarden-cli"
        echo "#TODO install nebula"
    fi
fi

# ask for hostname
read -rp "Hostname: " HOSTNAME
git_repo="https://git.withjt.net/devices/${HOSTNAME}.git"
if [[ "${OS_DISTRO}" != "nixos" ]]; then
    sudo hostnamectl set-hostname ${HOSTNAME}
fi

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
BITWARDEN_FOLDER="/nebula/hosts/${HOSTNAME}"
BITWARDEN_FOLDER_ID="$(
    bw list folders \
    | jq -er --arg name "$BITWARDEN_FOLDER" '
        [
            .[]
            | select(.name == $name)
        ]
        | if length == 1 then .[0].id
          elif length == 0 then
              error("Error: Unable to find file with name: " + $name)
          else
              error("Error: Multiple folders found with name: " + $name)
          end
    '
)"

# iterate secure notes
while IFS=$'\t' read -r ITEM_NAME ITEM_VALUE; do
    if [[ -z "$ITEM_VALUE" ]]; then
        echo "Error: Secure Note '$ITEM_NAME' has no contents" >&2
        exit 1
    fi
    if [[ "${ITEM_NAME}" == "config.yaml" ]]; then
        NEBULA_CONFIG_YAML="${ITEM_VALUE}"
        echo "Found config.yaml."
    elif [[ "${ITEM_NAME}" == "nebula.service" ]]; then
        NEBULA_SERVICE="${ITEM_VALUE}"
        echo "Found nebula.service."
    fi
done < <(
    bw list items \
    | jq -r --arg folder_id "$BITWARDEN_FOLDER_ID" '
        .[]
        | select(.folderId == $folder_id and .type == 2)
        | [.name, (.notes // "")]
        | @tsv
    '
)

# double check that we found everything
if [[ "${NEBULA_CONFIG_YAML}" == "" ]]; then
    # assume (though we may change this later) that certs are embedded in config
    echo "Error: Unable to find config.yaml in Bitwarden folder."
fi
if [[ "${OS_CLASS}" == "linux" && "${NEBULA_SERVICE}" == "" ]]; then
    # not required for macos
    echo "Error: Unable to find nebula.service in Bitwarden folder."
fi

echo "config.yaml"
echo "${NEBULA_CONFIG_YAML}"
echo ""
echo "nebula.service"
echo ""
exit 0

# connect to nebula
if [[ "${OS_CLASS}" == "macos" ]]; then
    sudo brew services stop nebula
    sudo echo "${NEBULA_CONFIG_YAML}" > /opt/homebrew/etc/nebula/config.yaml
    sudo brew services start nebula
elif [[ "${OS_CLASS}" == "linux" ]]; then
    if [[ "${OS_DISTRO}" == "alma" ]]; then
        sudo echo "${NEBULA_SERVICE}" > /etc/systemd/system/nebula.service
        sudo chown root:root /etc/systemd/system/nebula.service
        sudo restorecon -v /etc/systemd/system/nebula.service # selinux
        sudo systemctl daemon-reload
        sudo systemctl start nebula.service
    elif [[ "${OS_DISTRO}" == "arch" ]]; then
        sudo echo "${NEBULA_SERVICE}" > /etc/systemd/system/nebula.service
        sudo systemctl daemon-reload
        sudo systemctl start nebula.service
    elif [[ "${OS_DISTRO}" == "nixos" ]]; then
        # make a plan to clean up
        cleanup() {
            cleanup_bitwarden
            if [[ -n "$NEBULA_PID" ]] && kill -0 "$NEBULA_PID" 2>/dev/null; then
                sudo kill "$NEBULA_PID" 2>/dev/null || true
                wait "$NEBULA_PID" 2>/dev/null || true
            fi
        }
        trap cleanup EXIT INT TERM # this should override the other trap #TODO but test that assumption
        # start nebula
        sudo nebula -config "$NEBULA_CONFIG" &
        NEBULA_PID=$!
        # wait briefly for nebula to initialize
        sleep 2
        if ! kill -0 "$NEBULA_PID" 2>/dev/null; then
            # throw an error if nebula fails to start
            echo "Error: Nebula failed to start." >&2
            exit 1
        fi
    elif [[ "${OS_DISTRO}" == "ubuntu" ]]; then
        sudo echo "${NEBULA_SERVICE}" > /etc/systemd/system/nebula.service
        sudo systemctl daemon-reload
        sudo systemctl start nebula.service
    fi
else
    echo "Error: Unsupported operating system."
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
fi

# validate that the repo exists (indicating that the hostname is valid)
if ! git ls-remote "$REPO_URL" >/dev/null 2>&1; then
    echo "Error: Repository does not exist or is not accessible: $REPO_URL" >&2
    exit 1
fi

# download and execute further instructions
mkdir -p "${HOME}/git/${HOSTNAME}"
git -C "${HOME}/git/" clone "${git_repo}"
sh "${HOME}/git/${HOSTNAME}/install.sh"
