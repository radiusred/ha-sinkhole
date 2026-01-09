#!/usr/bin/env bash
# shellcheck shell=bash
#
# Wrapper script for the installer container for ha-sinkhole
#
# -------------------------------------------------------------------------
set -eou pipefail

readonly green='\033[0;32m'
readonly red='\033[0;31m'
readonly yellow='\033[0;33m'
readonly bold='\033[1m'
readonly reset='\033[0m' # No Color
readonly check_mark="${green}✔${reset}"
readonly cross_mark="${red}✘${reset}"

# Internal variables
inventory_file=""
playbook="install"
container_cmd=podman
manifest_url="https://github.com/radiusred/ha-sinkhole/releases/download/channel-manifest-artifact/manifest.yaml"
installer_container=""  # Will be set after parsing inventory and fetching manifest
native_mode=false

error_exit() {
    printf "${cross_mark} ERROR: $1\n" >&2
    if [[ -n "${logfile:-}" && -f "${logfile:-}" ]]; then
        read -r -e -p "  Would you like to review the log file (y/N)? " review < /dev/tty
        review=$(echo "$review" | tr '[:upper:]' '[:lower:]')
        if [[ "$review" == "y" || "$review" == "yes" ]]; then
            less "${logfile}"
        fi
    fi
    exit 1
}
ok() {
    printf "${check_mark} $1\n" >&1
}

usage() {
    printf "Usage: $0 -f <path/to/inventory.yaml> -c <command_to_execute>\n\n"
    printf "Options:\n"
    printf "  ${bold}-f${reset} <file>   Path to the .yaml or .yml inventory file.\n"
    printf "  ${bold}-c${reset} <cmd>    The command to execute (defaults to 'install').\n"
    printf "  ${bold}-l${reset}          Use a locally built installer (for development only).\n"
    printf "  ${bold}-n${reset}          Run Ansible natively (not in container).\n\n"
    printf "If options are missing, the script will prompt for values at runtime.\n\n"
    printf "${yellow}macOS Users:${reset}\n"
    printf "  Use native mode with ${bold}-n${reset} flag (requires: pipx install ansible-core)\n"
    printf "  Container mode has SSH and permission limitations on macOS.\n\n"
    printf "${yellow}General Requirements:${reset}\n"
    printf "  - SSH key authentication configured for target hosts\n"
    printf "  - Target hosts must have passwordless sudo configured\n\n"
    exit 0
}

get_channel_from_inventory() {
    local inventory=$1
    
    # Parse channel from inventory, default to 'stable' if not found
    local channel
    channel=$(grep -E "^\s*install_channel:" "${inventory}" | awk '{print $2}' | tr -d '"' | head -n1)
    
    if [[ -z "${channel}" ]]; then
        echo "stable"  # Default if not specified
    else
        echo "${channel}"
    fi
}

# Fetch and parse manifest to get installer version
get_installer_version() {
    local channel=$1
    
    # Fetch manifest
    local manifest
    if ! manifest=$(curl -sSfL "$manifest_url" 2>/dev/null); then
        error_exit "Failed to fetch manifest from ${bold}${manifest_url}${reset}"
    fi
    
    # Parse installer version from manifest
    local version
    version=$(echo "$manifest" | awk -v chan="${channel}:" '
        $0 ~ chan { in_channel=1 }
        in_channel && /installer:/ { 
            gsub(/[" ]/, "", $2)
            print $2
            exit
        }
    ')
    
    if [[ -z "$version" ]]; then
        error_exit "Could not find installer version for channel ${bold}${channel}${reset} in manifest"
    fi
    
    echo "${version}"
}

trap 'error_exit "SIGINT (Ctrl-C) detected."' SIGINT
trap 'error_exit "SIGTERM detected."' SIGTERM
trap 'error_exit "An unknown or unexpected error occurred."' ERR

printf "\n🌐  ${bold}Welcome to ha-sinkhole 🌐${reset}\n\n"

while getopts ":f:c:lnh" opt; do
    case "${opt}" in
        f)
            inventory_file="${OPTARG}"
            ;;
        c)
            playbook="${OPTARG}"
            ;;
        l)
            installer_container="localhost/ha-sinkhole/installer:local"
            ;;
        n)
            native_mode=true
            ;;
        h)
            usage 
            ;;
        :)
            # Handles missing argument for an option (e.g., $0 -f)
            error_exit "Missing argument for -${OPTARG}. See usage with -h."
            ;;
        ?)
            # Handles invalid options (e.g., $0 -x)
            error_exit "Invalid option: -${OPTARG}. See usage with -h."
            ;;
    esac
done

shift "$((OPTIND-1))"

ok "Checking environment..."

if ! command -v podman &> /dev/null; then
    container_cmd=docker
fi

if ! command -v $container_cmd &> /dev/null; then
    error_exit "Neither podman nor docker is installed. Please install one of them to proceed."
fi

if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S $SSH_AUTH_SOCK ]]; then
    error_exit "${bold}SSH_AUTH_SOCK${reset} is not set or is not accessible. Please ensure your SSH agent is running, your key is added and the environment variable is set."
fi

# Check if SSH agent has any keys loaded
if ! ssh-add -l &> /dev/null; then
    printf "${yellow}⚠${reset}  Warning: No SSH keys found in agent. You may need to run: ${bold}ssh-add ~/.ssh/id_ed25519${reset}\n"
    printf "   If your target hosts require SSH key authentication, the installation will fail.\n\n"
fi

# Prompt for inventory file if not provided
if [[ -z "$inventory_file" || ! -f "$inventory_file" ]]; then
    while true; do
        read -r -e -p $'\e[33m↪ Inventory file path:\e[0m ' input_file < /dev/tty
        input_file="${input_file/#\~/$HOME}"  # Expand ~ to $HOME

        # Check if the input is empty
        if [[ -z "$input_file" || "$input_file" =~ ^[[:space:]]*$ || ! -f "$input_file" ]]; then
            continue
        fi
        
        inventory_file="$input_file"
        break
    done
fi

# Convert inventory file path to absolute path for container mounting
if [[ ! "$inventory_file" = /* ]]; then
    inventory_file="$(cd "$(dirname "$inventory_file")" && pwd)/$(basename "$inventory_file")"
fi

# Set installer container version from manifest (unless using local)
if [[ -z "$installer_container" ]]; then
    channel=$(get_channel_from_inventory "$inventory_file")
    ok "Using install channel: ${bold}${channel}${reset}"
    ok "Finding installer version from ${bold}${channel}${reset} release manifest..."
    installer_version=$(get_installer_version "$channel")
    installer_container="ghcr.io/radiusred/ha-sinkhole/installer:${installer_version}"
    ok "Pulling installer container: ${bold}${installer_version}${reset}..."
    $container_cmd pull "$installer_container" > /dev/null 2>&1 || error_exit "Failed to pull installer container: ${bold}${installer_container}${reset}"
fi

logfile=$(mktemp /tmp/ha-sinkhole-log.XXXXXX)
ok "Running remote ${playbook}, this may take a minute or two. The full log is at ${bold}$logfile${reset}\n"

if [[ "$native_mode" == "true" ]]; then
    # Native mode: run ansible-playbook directly on the host
    if ! command -v ansible-playbook &> /dev/null; then
        error_exit "ansible-playbook not found. Install with: ${bold}pipx install ansible-core${reset}"
    fi
    
    # Extract playbook from container to temp directory
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    $container_cmd create --name ha-sinkhole-installer-temp "$installer_container" > /dev/null
    $container_cmd cp ha-sinkhole-installer-temp:/home/ansible/. "$temp_dir/"
    $container_cmd rm ha-sinkhole-installer-temp > /dev/null
    
    # Run ansible-playbook natively
    cd "$temp_dir"
    ansible-playbook -i "$inventory_file" "playbooks/$playbook.yaml" > "$logfile" 2>&1 || {
        # Don't exit immediately - let the error checking below provide better messages
        :
    }
else
    # Container mode: run in container
    # Build container command with platform-specific networking and SSH handling
    network_args=()
    ssh_mount_args=()
    userns_args=()

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: SSH agent sockets from launchd can't be mounted into containers
        # Mount .ssh directory (note: has limitations, native mode recommended)
        userns_args=(--userns=keep-id)
        if [[ -d "$HOME/.ssh" ]]; then
            ssh_mount_args=(-v "$HOME/.ssh:/home/ansible/.ssh:ro")
        fi
    else
        # Linux: Use host networking and mount SSH agent socket
        network_args=(--net=host)
        userns_args=(--userns=keep-id)
        if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
            ssh_mount_args=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock")
        fi
    fi

    $container_cmd run \
        --rm \
        ${network_args[@]+"${network_args[@]}"} \
        ${userns_args[@]+"${userns_args[@]}"} \
        --name ha-sinkhole-installer \
        -v "$inventory_file":/home/ansible/inventory.yaml \
        ${ssh_mount_args[@]+"${ssh_mount_args[@]}"} \
        $installer_container \
        playbooks/"$playbook".yaml > "$logfile" 2>&1 || {
            # Don't exit immediately - let the error checking below provide better messages
            :
        }
fi

# check common issues
if grep -q "UNREACHABLE!" "${logfile}"; then
    if [[ "$(uname)" == "Darwin" ]] && grep -q "Permission denied" "${logfile}"; then
        # macOS-specific SSH auth issue
        printf "${cross_mark} ERROR: SSH authentication failed.\n" >&2
        printf "\n${yellow}macOS:${reset} Container mode has SSH authentication limitations.\n" >&2
        printf "  Use native mode: ${bold}$0 -f $inventory_file -n${reset}\n\n" >&2
    else
        error_exit "Some hosts were unreachable during installation."
    fi
    exit 1
fi
if grep -q "FAILED!" "${logfile}"; then
    error_exit "Some tasks failed during installation."
fi
if grep -q "Unable to parse /home/ansible/inventory.yaml" "${logfile}"; then
    error_exit "Inventory could not be parsed, please check your ${bold}${inventory_file}${reset} file."
fi

# If we get here and there were errors, show a generic message
if grep -q "failed=0" "${logfile}" && grep -q "unreachable=0" "${logfile}"; then
    awk '/PLAY RECAP/{p=1; next} p' ${logfile}
    ok "Success! 🎉\n"
    exit 0
else
    error_exit "Installation completed with errors. Check the log for details."
fi
