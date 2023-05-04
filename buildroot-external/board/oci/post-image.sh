#!/bin/bash

# Stop on error
set -e

# show all executions
set -x

BOARD_DIR="$(dirname "$0")"
BOARD_NAME="$(basename "${BOARD_DIR}")"

# define DOCKER_ARCH on the BR2_CONFIG setup
if grep -Eq "^BR2_x86_64=y$" "${BR2_CONFIG}"; then
  DOCKER_ARCH=amd64
elif grep -Eq "^BR2_i386=y$" "${BR2_CONFIG}"; then
  DOCKER_ARCH=i386
elif grep -Eq "^BR2_aarch64=y$" "${BR2_CONFIG}"; then
  DOCKER_ARCH=arm64
elif grep -Eq "^BR2_arm=y$" "${BR2_CONFIG}"; then
  DOCKER_ARCH=arm
else
  echo "Unknown architecture"
  exit 1
fi

# make sure a factory reset is performed upon fresh start
touch "${TARGET_DIR}/usr/local/.doFactoryReset"

# output info on docker
which docker
docker version

# build docker image
if ! docker build --file="${BOARD_DIR}/Dockerfile" --build-arg=tar_prefix=rootfs --platform=linux/${DOCKER_ARCH} --tag="raspberrymatic:${DOCKER_ARCH}-${PRODUCT_VERSION}" --tag="raspberrymatic:${DOCKER_ARCH}-latest" "${BINARIES_DIR}"; then
  exit 1
fi

# save docker image
if ! docker save "raspberrymatic:${DOCKER_ARCH}-${PRODUCT_VERSION}" >"${BINARIES_DIR}/RaspberryMatic-${PRODUCT_VERSION}-${BOARD_NAME}_${DOCKER_ARCH}.tar"; then
  exit 1
fi

# cleanup temporarily built docker image
if ! docker image rm --force "$(docker images --filter="reference=raspberrymatic:${DOCKER_ARCH}-${PRODUCT_VERSION}" -q)"; then
  exit 1
fi
