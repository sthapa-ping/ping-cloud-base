#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

"${VERBOSE}" && set -x

# Do not proceed to attempt to restore a backup from s3 if RESTORE_BACKUP set to false
if $(echo "${RESTORE_BACKUP}" | grep -iq "false"); then
  beluga_log "RESTORE_BACKUP is false, skipping..."
  exit 0
fi

# 1) Specified backup file name by user will be restored
#
# OR
#
# 2) If the master key doesn't exist within the image. There may have been 
#    an issue with the EBS volume which the 90-restore-backup-s3.sh restore script
#    will restore the latest configuration from S3. If this is an initial
#    deployment the restore scipt will not find any backups within S3.

if ! test -z "${BACKUP_FILE_NAME}" || ! test -f "${OUT_DIR}"/instance/conf/pa.jwk; then

  beluga_log "Restoring from location ${BACKUP_URL}"
  
  # Set required environment variables for skbn
  initializeSkbnConfiguration "${PA_DATA_BACKUP_URL}"

  # This is the backup directory on the server
  SERVER_RESTORE_DIR="/tmp/restore"
  rm -rf "${SERVER_RESTORE_DIR}"
  mkdir -p "${SERVER_RESTORE_DIR}"

  DATA_BACKUP_FILE_NAME=$( echo "${BACKUP_FILE_NAME}" | tr -d '"' | tr -d '[:space:]' )
  if ! test -z "${DATA_BACKUP_FILE_NAME}" && \
     ! test "${DATA_BACKUP_FILE_NAME}" = 'null'; then

    beluga_log "Attempting to restore backup from S3 specified by the user: ${DATA_BACKUP_FILE_NAME}"

  else

    beluga_log "Attempting to restore backup from latest backup file in cloud storage."
    DATA_BACKUP_FILE_NAME="latest.zip"
  fi

  # Rename s3 backup filename when copying onto pingaccess admin
  DST_FILE="data.zip"

  beluga_log "Copying: '${DATA_BACKUP_FILE_NAME}' to '${SKBN_K8S_PREFIX}${SERVER_RESTORE_DIR}/${DST_FILE}'"

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

    # PDO-1076 - Proactively delete the H2 database password backup file if it exists
    readonly h2_props_backup="${SERVER_ROOT_DIR}/conf/h2_password_properties.backup"
    if [ -f "${h2_props_backup}" ]; then
      beluga_log "Found the H2 database password properties file: ${h2_props_backup}.  Removing this file before unzipping the backup."
      rm -f "${h2_props_backup}"
    fi

    beluga_log "importing configuration"

    # Unzip backup configuration
    unzip -o "${SERVER_RESTORE_DIR}/${DST_FILE}" -d "${OUT_DIR}/instance"

    # Remove zip
    rm -rf "${SERVER_RESTORE_DIR}/${DST_FILE}"

    # Print the filename of the downloaded file from s3
    beluga_log "Downloaded file name: ${DATA_BACKUP_FILE_NAME}"

    # If ADMIN_CONFIGURATION_COMPLETE does not exist then set restore configuration.
    ADMIN_CONFIGURATION_COMPLETE="${OUT_DIR}/instance/ADMIN_CONFIGURATION_COMPLETE"
    ! test -f "${ADMIN_CONFIGURATION_COMPLETE}" && touch "${ADMIN_CONFIGURATION_COMPLETE}"

    # Write password admin password to disk after successful restore
    createSecretFile

  else 
    beluga_log "No archive data found"
  fi  
fi
