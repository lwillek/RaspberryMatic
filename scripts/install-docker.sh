#!/bin/bash
#
# Script to install the RaspberryMatic container and its dependencies
# https://github.com/jens-maus/RaspberryMatic/wiki/en.Installation-Docker-OCI
#
# Copyright (c) 2022-2023 Jens Maus <mail@jens-maus.de>
# Apache 2.0 License applies
#
# Usage:
# wget -qO - https://raspberrymatic.de/install-docker.sh | bash -
#

#############################################################
#                           Settings                        #
#############################################################

# Name of the docker volume where CCU data will persist
# It can be a local location as well such as a mounted NAS folder, cluster fs (glusterfs), etc.
: "${CCU_DATA_VOLUME:="ccu_data"}"

# Container repository to use
: "${CCU_OCI_REPO:="ghcr.io/jens-maus/raspberrymatic"}"

# CCU version to use
: "${CCU_OCI_TAG:="latest"}"

# Name of the container instance (by default use same as angelnu/ccu for easier migration)
: "${CCU_CONTAINER_NAME:="ccu"}"

# IP address of the container interface
: "${CCU_CONTAINER_IP:=""}"

# IP aux address of the container host
: "${CCU_CONTAINER_IP_AUX:=""}"

# Name of the container network
: "${CCU_NETWORK_NAME:="ccu"}"

# Name of the container network interface
: "${CCU_NETWORK_INTERFACE:=""}"

# Network subnet
: "${CCU_NETWORK_SUBNET:=""}"

# Additional options for docker run
: "${CCU_DOCKER_RUN_OPTIONS:=""}"

# Additional options for docker pull
: "${CCU_DOCKER_PULL_OPTIONS:=""}"

# Do a docker pull to refresh image
: "${CCU_DOCKER_PULL_REFRESH:="true"}"

# Time for a clean container stop before it gets killed
: "${CCU_DOCKER_STOP_TIMEOUT:="30"}"

#############################################################
#                       Helper functions                    #
#############################################################

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
shopt -s expand_aliases
alias die='EXIT=$? LINE=${LINENO} error_exit'
trap die ERR

# Set default variables
VERSION="1.3"
LINE=

error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m${EXIT}@${LINE}"
  msg "${FLAG} ${REASON}"
  exit "${EXIT}"
}
warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "${FLAG} ${REASON}"
}
info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "${FLAG} ${REASON}"
}
msg() {
  local TEXT="$1"
  echo -e "${TEXT}"
}

check_sudo() {
  # Make sure only root can run our script
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root/sudo to modify host settings"
    exit 1
  fi
}

pkg_installed() {
  PKG=${1}
  if dpkg -s "${PKG}" 2>/dev/null | grep -Eq "^Status:.*installed.*"; then
    return 0
  else
    return 1
  fi
}

uninstall() {
  msg "Purging/Uninstalling container installation:"
  check_sudo
  if docker container inspect "${CCU_CONTAINER_NAME}" >/dev/null 2>&1; then
    msg "Removing ${CCU_CONTAINER_NAME} container (not user data)"
    docker stop "${CCU_CONTAINER_NAME}" >/dev/null || true
    docker rm "${CCU_CONTAINER_NAME}" >/dev/null || true
  fi
  if docker network inspect "${CCU_NETWORK_NAME}" >/dev/null 2>&1; then
    msg "Removing ${CCU_NETWORK_NAME} macvlan docker network"
    docker network rm "${CCU_NETWORK_NAME}"
  fi
  if [[ -e /etc/network/if-up.d/99-ccu-shim-network ]]; then
    msg "Removing /etc/network/if-up.d/99-ccu-shim-network"
    rm -f /etc/network/if-up.d/99-ccu-shim-network
  fi
  if [[ -e /etc/udev/rules.d/99-Homematic.rules ]]; then
    msg "Removing /etc/udev/rules.d/99-Homematic.rules"
    rm -f /etc/udev/rules.d/99-Homematic.rules
  fi
  if [[ -e /etc/modules-load.d/eq3_char_loop.conf ]]; then
    msg "Removing /etc/modules-load.d/eq3_char_loop.conf"
    rm -f /etc/modules-load.d/eq3_char_loop.conf
  fi
  if pkg_installed pivccu-modules-dkms; then
    msg "Purging pivccu-modules-dkms package install"
    apt purge pivccu-modules-dkms
  fi
  if pkg_installed pivccu-devicetree-armbian; then
    msg "Purging pivccu-devicetree-armbian package install"
    apt purge pivccu-devicetree-armbian
  fi
  if pkg_installed pivccu-modules-raspberrypi; then
    msg "Purging pivccu-modules-raspberrypi package install"
    apt purge pivccu-modules-raspberrypi
  fi
  if [[ -e /etc/apt/sources.list.d/pivccu.list ]]; then
    msg "Removing /etc/apt/sources.list.d/pivccu.list"
    rm -f /etc/apt/sources.list.d/pivccu.list
  fi
  if [[ -e /usr/share/keyrings/pivccu-archive-keyring.gpg ]]; then
    msg "Removing /usr/share/keyrings/pivccu-archive-keyring.gpg"
    rm -f /usr/share/keyrings/pivccu-archive-keyring.gpg
  fi

  echo
  msg  "Docker container environment successfully removed."
  msg  "- CCU user data volume (${CCU_DATA_VOLUME}) was not removed."
  msg  "- Manually purge user data volume with \"docker volume rm ${CCU_DATA_VOLUME}\""
  msg  "- Container images have not been removed. Revisit with \"docker image ls\""
  msg  "- Reboot your host system to cleanup still running processes."
}

#############################################################
#                    PARAMETER QUERY                        #
#############################################################

msg "RaspberryMatic Docker installation script v${VERSION}"
msg "Copyright (c) 2022-2023 Jens Maus <mail@jens-maus.de>"
msg ""

# check if docker exists
if ! command -v docker >/dev/null; then
  die "No docker installation found, check documentation (raspberrymatic.de)"
fi

# make sure apt/dpkg won't interact with us
export DEBIAN_FRONTEND=noninteractive

# when executing with "uninstall" remove/purge all config files
if [[ "${1-}" == "uninstall" ]]; then
  uninstall
  exit 0
fi

if [[ -z "${CCU_NETWORK_INTERFACE}" ]]; then
  # get default
  default=$(ip -o -f inet route |grep -e "^default" |awk '{print $5}')
  read -r -e -p "Container Host Bridge Interface (e.g. eth0): " -i "${default}" CCU_NETWORK_INTERFACE </dev/tty
else
  msg "Used host<>container bridge interface: ${CCU_NETWORK_INTERFACE}"
fi

# try to acquire subnet definition from interface routes first
if [[ -z "${CCU_NETWORK_SUBNET}" ]]; then
  CCU_NETWORK_SUBNET=$(ip -o -f inet addr show dev "${CCU_NETWORK_INTERFACE}" | awk '/scope global/ {print $4}')
fi
if [[ -z "${CCU_NETWORK_SUBNET}" ]]; then
  read -r -p 'Container Host Bridge Subnet (e.g. 192.168.178.0/24): ' CCU_NETWORK_SUBNET </dev/tty
else
  msg "Used host<>container bridge subnet: ${CCU_NETWORK_SUBNET}"
fi

if [[ -z "${CCU_CONTAINER_IP}" ]]; then
  read -r -p 'Container IP (e.g. 192.168.178.4): ' CCU_CONTAINER_IP </dev/tty
  if [[ -z "${CCU_CONTAINER_IP}" ]]; then
    die "Must specify a free ip to assign to RaspberryMatic container"
  fi
else
  msg "Used RaspberryMatic container ip: ${CCU_CONTAINER_IP}"
fi

if [[ -z "${CCU_CONTAINER_IP_AUX}" ]]; then
  read -r -p 'Container Host Aux-IP (e.g. 192.168.178.3): ' CCU_CONTAINER_IP_AUX </dev/tty
  if [[ -z "${CCU_CONTAINER_IP_AUX}" ]]; then
    die "Must specify a free ip which can be assigned to container host"
  fi
else
  msg "Used container host auxiliary ip: ${CCU_CONTAINER_IP_AUX}"
fi

#############################################################
#                 DEPENDENCY INSTALLATION                   #
#############################################################

# This only works on Debian/Ubuntu based OSes including Armbian and Raspberry Pi OS
if command -v dpkg >/dev/null; then

  # Add repository
  if [[ ! -e /etc/apt/sources.list.d/pivccu.list ]]; then
    msg "Adding piVCCU apt repository"
    check_sudo
    if ! pkg_installed wget; then
      apt install wget
    fi
    if ! pkg_installed ca-certificates; then
      apt install ca-certificates
    fi
    if ! pkg_installed build-essential; then
      apt install build-essential
    fi
    if ! pkg_installed bison; then
      apt install bison
    fi
    if ! pkg_installed flex; then
      apt install flex
    fi
    if ! pkg_installed libssl-dev; then
      apt install libssl-dev
    fi
    if ! pkg_installed gpg; then
      apt install gpg
    fi

    # use gpg to dearmor the pivccu public key
    wget -qO - https://apt.pivccu.de/piVCCU/public.key | gpg --dearmor -o /usr/share/keyrings/pivccu-archive-keyring.gpg
    sh -c 'echo "deb [signed-by=/usr/share/keyrings/pivccu-archive-keyring.gpg] https://apt.pivccu.de/piVCCU stable main" >/etc/apt/sources.list.d/pivccu.list'
    apt update
  fi

  # Install kernel headers
  if command -v armbian-config >/dev/null; then
    msg "Detected Armbian - install kernel sources and device tree"
    check_sudo
    apt install "$(dpkg --get-selections | grep 'linux-image-' | grep '\sinstall' | sed -e 's/linux-image-\([a-z0-9-]\+\).*/linux-headers-\1/')"
    if ! pkg_installed pivccu-devicetree-armbian; then
      check_sudo
      apt install pivccu-devicetree-armbian
    fi
  elif grep -q Raspberry /proc/cpuinfo; then
    if ! pkg_installed pivccu-modules-raspberrypi; then
      msg "Detected RaspberryPi - install kernel sources and raspberry modules"
      check_sudo
      apt install pivccu-modules-raspberrypi
      echo
      msg "NOTE: please ensure that your GPIO UART is free if you plan to connect your CCU adapter to it"
      msg "See step 5 and 6 at https://github.com/alexreinert/piVCCU/blob/master/docs/setup/raspberrypi.md"
    fi
  elif ! pkg_installed "linux-headers-generic"; then
    msg "Generic Debian/Ubuntu platform - trying generic way to install kernel headers"
    check_sudo
    apt install "linux-headers-generic"
  fi

  # Install & Build kernel modules
  if ! pkg_installed pivccu-modules-dkms; then
    msg "Installing and building kernel modules..."
    check_sudo
    apt install pivccu-modules-dkms
    service pivccu-dkms start
  fi
fi

# setup /dev/eq3loop
if [[ ! -c /dev/eq3loop ]]; then
  msg "Loading eq3_char_loop module"
  check_sudo
  if ! modprobe eq3_char_loop; then
    apt install --reinstall pivccu-modules-dkms
    modprobe eq3_char_loop
  fi
fi
if [[ ! -e /etc/modules-load.d/eq3_char_loop.conf ]]; then
  msg "Installing eq3_char_loop to /etc/modules-load.d"
  check_sudo
  echo eq3_char_loop >/etc/modules-load.d/eq3_char_loop.conf
fi

if [[ -e /etc/udev/rules.d/10-hmiprfusb.rules ]]; then
  msg "Deleting 10-hmiprfusb udev rule"
  rm -f /etc/udev/rules.d/10-hmiprfusb.rules
fi

if [[ ! -e /etc/udev/rules.d/99-Homematic.rules ]]; then
  msg "Adding/Updating udev rule"
  check_sudo
  cat <<'EOF' >/etc/udev/rules.d/99-Homematic.rules
ATTRS{idVendor}=="1b1f" ATTRS{idProduct}=="c020", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="1b1f" ATTRS{idProduct}=="c00f", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="0403" ATTRS{idProduct}=="6f70", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="10c4" ATTRS{idProduct}=="8c07", ENV{ID_MM_DEVICE_IGNORE}="1"
EOF
  udevadm control --reload-rules
  udevadm trigger --action=add
fi

#############################################################
#                      CONTAINER UPDATE                     #
#############################################################

if docker container inspect "${CCU_CONTAINER_NAME}" >/dev/null 2>&1; then
  msg "Removing old container (not user data)"
  docker stop "${CCU_CONTAINER_NAME}" >/dev/null || true
  docker rm "${CCU_CONTAINER_NAME}" >/dev/null || true
fi

DOCKER_IMAGE="${CCU_OCI_REPO}:${CCU_OCI_TAG}"
if [[ "${CCU_DOCKER_PULL_REFRESH}" == "true" ]]; then
  msg "Pull/Update OCI image ${DOCKER_IMAGE}"
  # shellcheck disable=SC2086
  docker pull ${CCU_DOCKER_PULL_OPTIONS} "${DOCKER_IMAGE}"
fi

#############################################################
#                   CONTAINER NETWORK SETUP                 #
#############################################################

# skip if NETWORK_NAME is none
if [[ "${CCU_NETWORK_NAME}" != "none" ]]; then
  if docker network inspect "${CCU_NETWORK_NAME}" >/dev/null 2>&1; then
    msg "Removing old macvlan docker network:"
    docker network rm "${CCU_NETWORK_NAME}"
  fi

  msg "Creating macvlan docker network:"
  docker network create -d macvlan \
    --opt parent="${CCU_NETWORK_INTERFACE}" \
    --subnet "${CCU_NETWORK_SUBNET}" \
    "${CCU_NETWORK_NAME}"

  # make network shim interface persistent
  if [[ ! -e /etc/network/if-up.d/99-ccu-shim-network ]]; then
    msg "Setup local network bridge persistence..."
    check_sudo
    cat <<EOF >/etc/network/if-up.d/99-ccu-shim-network
#!/bin/sh
if [ "\$IFACE" = "${CCU_NETWORK_INTERFACE}" ]; then
  if ! ip link show ccu-shim >/dev/null 2>&1; then
    ip link add ccu-shim link ${CCU_NETWORK_INTERFACE} type macvlan mode bridge
    ip addr add ${CCU_CONTAINER_IP_AUX} dev ccu-shim
    ip link set ccu-shim up
    ip route add ${CCU_CONTAINER_IP} dev ccu-shim protocol static
  fi
fi
EOF
    chmod a+rx /etc/network/if-up.d/99-ccu-shim-network
  fi

  if ! ip link show ccu-shim >/dev/null 2>&1; then
    msg "Setup local network bridge..."
    check_sudo
    IFACE="${CCU_NETWORK_INTERFACE}" /etc/network/if-up.d/99-ccu-shim-network
  fi
fi

#############################################################
#                       DOCKER CREATE                       #
#############################################################

msg "Creating container:"
DOCKER_COMMAND="docker create"

# system capabilities additions
#DOCKER_COMMAND="${DOCKER_COMMAND} --cap-add SYS_ADMIN --cap-add SYS_MODULE --cap-add SYS_NICE --cap-add SYS_RAWIO --security-opt seccomp=unconfined --security-opt apparmor:unconfined"
DOCKER_COMMAND="${DOCKER_COMMAND} --privileged"

# check for CONFIG_RT_GROUP_SCHED in kernel and if so
# add options to provide enough cpu shares to the ccu container
if [[ -e /sys/fs/cgroup/cpu/cpu.rt_runtime_us ]]; then
  DOCKER_COMMAND="${DOCKER_COMMAND} --cpu-rt-runtime 950000 --ulimit rtprio=99"
fi

# Persistent volume
DOCKER_COMMAND="${DOCKER_COMMAND} --volume ${CCU_DATA_VOLUME}:/usr/local:rw --volume /lib/modules:/lib/modules:ro --volume /run/udev/control:/run/udev/control"

# Container and host names
DOCKER_COMMAND="${DOCKER_COMMAND} --hostname ${CCU_CONTAINER_NAME} --name ${CCU_CONTAINER_NAME}"

# Add timeout
DOCKER_COMMAND="${DOCKER_COMMAND} --stop-timeout ${CCU_DOCKER_STOP_TIMEOUT} --restart always"

# Add network
if [[ "${CCU_NETWORK_NAME}" != "none" ]]; then
  DOCKER_COMMAND="${DOCKER_COMMAND} --network ${CCU_NETWORK_NAME} --ip ${CCU_CONTAINER_IP}"
fi

# Add extra user options
DOCKER_COMMAND="${DOCKER_COMMAND} ${CCU_DOCKER_RUN_OPTIONS}"

# Add container repo
DOCKER_COMMAND="${DOCKER_COMMAND} ${DOCKER_IMAGE}"

# Execute docker command
msg "${DOCKER_COMMAND}"
if ${DOCKER_COMMAND} >/dev/null; then
  echo
  msg  "Docker container successfully created."
  msg  "- Start container with \"docker start ccu\""
  msg  "- See logs with \"docker logs ${CCU_CONTAINER_NAME}\""
  msg  "- Connect to http://${CCU_CONTAINER_IP}/"
  msg  "- Stop container with \"docker stop ccu\""
  msg  "- Uninstall container environment with \"${0} uninstall\""
  exit 0
else
  echo
  die "Failed to create docker container '${CCU_CONTAINER_NAME}'"
fi
