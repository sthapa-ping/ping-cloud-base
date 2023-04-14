#!/usr/bin/env sh

${VERBOSE} && set -x

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

if test "${OPERATIONAL_MODE}" != "CLUSTERED_CONSOLE"; then
  beluga_log "post-start: skipping post-start on engine"
  exit 0
fi

beluga_log "post-start: starting admin post-start initialization"

# Remove the marker file before running post-start initialization.
rm -f "${POST_START_INIT_MARKER_FILE}"

# Wait until the admin API is up and running.
beluga_log "post-start: waiting for admin API to be ready"
wait_for_admin_api_endpoint configArchive/export

# Replicate admin changes to engine(s)
beluga_log "post-start: Replicating admin changes to engine(s)"
sh "${HOOKS_DIR}/95-replicate-engines.sh"
REPLICATION_STATUS=${?}
beluga_log "post-start: engine replication status: ${REPLICATION_STATUS}"

# Upload a backup right away after starting the server.
beluga_log "post-start: uploading data backup to s3"
sh "${HOOKS_DIR}/90-upload-backup-s3.sh"
BACKUP_STATUS=${?}
beluga_log "post-start: data backup status: ${BACKUP_STATUS}"

# Write the marker file if post-start succeeds.
if test "${BACKUP_STATUS}" -eq 0 && test "${REPLICATION_STATUS}" -eq 0; then
  touch "${POST_START_INIT_MARKER_FILE}"
  exit 0
fi

# Kill the container if post-start fails.
beluga_log "post-start: admin post-start initialization failed"
SERVER_PID=$(pgrep -alf java | grep 'run.properties' | awk '{ print $1; }')
kill "${SERVER_PID}"