#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

${VERBOSE} && set -x

# Allow overriding the backup URL with an arg
test ! -z "${1}" && BACKUP_URL="${1}"

# Do not proceed to attempt to restore a backup from s3 if RESTORE_BACKUP set to false
if $(echo "${RESTORE_BACKUP}" | grep -iq "false"); then
  beluga_log "RESTORE_BACKUP is false, skipping..."
  exit 0
fi

beluga_log "Downloading from location ${BACKUP_URL}"

set_script_variables() {
  # This is the backup directory on the server
  SERVER_RESTORE_DIR=$(mktemp -d)
  MASTER_KEY_FILE=pf.jwk
  MASTER_KEY_PATH="${SERVER_ROOT_DIR}/server/default/data/${MASTER_KEY_FILE}"
  DEPLOYER_PATH="${SERVER_ROOT_DIR}/server/default/data/drop-in-deployer"

  DATA_BACKUP_FILE_NAME=$( echo "${BACKUP_FILE_NAME}" | tr -d '"' | tr -d '[:space:]' )
  if ! test -z "${DATA_BACKUP_FILE_NAME}" && \
    ! test "${DATA_BACKUP_FILE_NAME}" = 'null'; then

    beluga_log "Attempting to restore backup from cloud storage specified by the user: ${DATA_BACKUP_FILE_NAME}"
  else
    beluga_log "Attempting to restore backup from latest backup file in cloud storage."
    DATA_BACKUP_FILE_NAME="latest.zip"
  fi

  # Rename backup filename when copying onto pingfederate admin
  DST_FILE="data.zip"
}

# Set required environment variables for skbn
initializeSkbnConfiguration

set_script_variables

beluga_log "Copying: '${DATA_BACKUP_FILE_NAME}' to '${SKBN_K8S_PREFIX}${SERVER_RESTORE_DIR}'"

if ! skbnCopy "${SKBN_CLOUD_PREFIX}/${DATA_BACKUP_FILE_NAME}" "${SKBN_K8S_PREFIX}${SERVER_RESTORE_DIR}/${DST_FILE}"; then
  beluga_log "Cannot locate s3 bucket ${SKBN_CLOUD_PREFIX}/${DATA_BACKUP_FILE_NAME}"
  exit 1
fi

# Check if file exists
if test -f "${SERVER_RESTORE_DIR}/${DST_FILE}"; then

  # Validate zip.
  beluga_log "Validating downloaded backup archive"
  if test $(unzip -t  "${SERVER_RESTORE_DIR}/${DST_FILE}" &> /dev/null; echo $?) -ne 0; then
    beluga_log "Failed to validate backup archive to restore"
    exit 1
  fi

  beluga_log "Extracting config export to ${SERVER_RESTORE_DIR}"
  unzip -o "${SERVER_RESTORE_DIR}/${DST_FILE}" -d "${SERVER_RESTORE_DIR}"

  # Copy master key to server directory
  find "${SERVER_RESTORE_DIR}" -type f -name "${MASTER_KEY_FILE}" | xargs -I {} cp {} "${MASTER_KEY_PATH}"
  test ! -f "${MASTER_KEY_PATH}" && beluga_log "Unable to locate master key" && exit 1
  chmod 400 "${MASTER_KEY_PATH}"

  # Deploy configuration using drop-in-deployer
  rm -rf "${DEPLOYER_PATH}"/*
  cp "${SERVER_RESTORE_DIR}/${DST_FILE}" "${DEPLOYER_PATH}"

  # Print the filename of the downloaded file from cloud storage.
  beluga_log "Download file name: ${DATA_BACKUP_FILE_NAME}"

  # Print listed files from drop-in-deployer
  ls ${DEPLOYER_PATH}

else 
  beluga_log "No archive data found"
fi  