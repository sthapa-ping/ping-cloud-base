#!/bin/sh -e

# This script copies the kustomization templates into a temporary directory, performs substitution into them using
# environment variables defined in an env_vars file and builds the uber deploy.yaml file. It is run by the CD tool on
# every poll interval.

LOG_FILE=/tmp/git-ops-command.log

########################################################################################################################
# Add the provided message to LOG_FILE.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
log() {
  msg="$1"
  echo "${msg}" >> "${LOG_FILE}"
}

########################################################################################################################
# Substitute variables in all files in the provided directory with the values provided through the environments file.
#
# Arguments
#   $1 -> The file containing the environment variables to substitute.
#   $2 -> The directory that contains the files where variables must be substituted.
########################################################################################################################
substitute_vars() {
  env_file="$1"
  subst_dir="$2"

  log "git-ops-command: substituting variables in '${env_file}' in directory ${subst_dir}"

  # Create a list of variables to substitute
  vars="$(grep -Ev "^$|#" "${env_file}" | cut -d= -f1 | awk '{ print "${" $1 "}" }')"
  log "git-ops-command: substituting variables '${vars}'"

  # Export the environment variables
  set -a; . "${env_file}"; set +a

  for file in $(find "${subst_dir}" -type f); do
    old_file="${file}.bak"
    cp "${file}" "${old_file}"

    envsubst "${vars}" < "${old_file}" > "${file}"
    rm -f "${old_file}"
  done
}

########################################################################################################################
# Clean up on exit. If non-zero exit, then print the log file to stdout before deleting it. Change back to the previous
# directory. Delete the kustomize build directory, if it exists.
########################################################################################################################
cleanup() {
  test $? -ne 0 && cat "${LOG_FILE}"
  rm -f "${LOG_FILE}"
  cd - >/dev/null 2>&1
  test ! -z "${TMP_DIR}" && rm -rf "${TMP_DIR}"
}

# Main script
TARGET_DIR="${1:-.}"
cd "${TARGET_DIR}" >/dev/null 2>&1

# Trap all exit codes from here on so cleanup is run
trap "cleanup" EXIT

# Get short and full directory names of the target directory
TARGET_DIR_FULL="$(pwd)"
TARGET_DIR_SHORT="$(basename "${TARGET_DIR_FULL}")"

# Directory paths relative to TARGET_DIR
TOOLS_DIR='cluster-tools'
PING_CLOUD_DIR='ping-cloud'
BASE_DIR='../base'

# Perform substitution and build in a temporary directory
TMP_DIR="$(mktemp -d)"
BUILD_DIR="${TMP_DIR}/${TARGET_DIR_SHORT}"

# Copy contents of target directory into temporary directory
log "git-ops-command: copying templates into '${TMP_DIR}'"
cp -pr "${TARGET_DIR_FULL}" "${TMP_DIR}"
test -d "${BASE_DIR}" && cp -pr "${BASE_DIR}" "${TMP_DIR}"

# If there's an environment file, then perform substitution
if test -f 'env_vars'; then
  # Perform the substitutions in a sub-shell so it doesn't pollute the current shell.
  log "git-ops-command: substituting env_vars into templates"
  (
    cd "${BUILD_DIR}"

    BASE_ENV_VARS="${BASE_DIR}"/env_vars
    env_vars_file=env_vars

    if test -f "${BASE_ENV_VARS}"; then
      env_vars_file="$(mktemp)"
      cat env_vars "${BASE_ENV_VARS}" > "${env_vars_file}"
      substitute_vars "${env_vars_file}" "${BASE_DIR}"
    fi

    substitute_vars "${env_vars_file}" .
  )
  test $? -ne 0 && exit 1
fi

# Build the uber deploy yaml
if test -z "${OUT_DIR}" || test ! -d "${OUT_DIR}"; then
  log "git-ops-command: generating uber yaml file from '${BUILD_DIR}' to stdout"
  kustomize build --load_restrictor none "${BUILD_DIR}"
else
  log "git-ops-command: generating yaml files from '${BUILD_DIR}' to '${OUT_DIR}'"
  kustomize build --load_restrictor none "${BUILD_DIR}" --output "${OUT_DIR}"
fi

exit 0