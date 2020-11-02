#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

"${VERBOSE}" && set -x

templates_dir_path=${STAGING_DIR}/templates/81
PINGACCESS_ADMIN_API_ENDPOINT="https://localhost:9000/pa-admin-api/v3"

# Fetch using the -i flag to get the HTTP response
# headers as well
set +x
get_admin_user_response=$(curl -k \
     -i \
     --retry ${API_RETRY_LIMIT} \
     --max-time ${API_TIMEOUT_WAIT} \
     --retry-delay 1 \
     --retry-connrefused \
     -u ${PA_ADMIN_USER_USERNAME}:${OLD_PA_ADMIN_USER_PASSWORD} \
     -H "X-Xsrf-Header: PingAccess" "${PINGACCESS_ADMIN_API_ENDPOINT}/users/1")
"${VERBOSE}" && set -x

# Verify connecting to the user endpoint using credentials
# passed in via env variables.  If this fails with a non-200
# HTTP response then skip the configuration import.
http_response_code=$(printf "${get_admin_user_response}" | awk '/HTTP/' | awk '{print $2}')
beluga_log "${http_response_code}"
if [ 200 = ${http_response_code} ]; then

    admin_user_json=$(printf "${get_admin_user_response}" | awk '/firstLogin/' | awk '{print $0}')
    first_login=$(jq -n "${admin_user_json}" | jq '.firstLogin')

    # Only configure PingAccess if this is the first time
    # through.  We shouldn't clobber an existing configuration.
    if [ 'true' = ${first_login} ]; then

        # Accept EULA
        beluga_log "Accepting the EULA..."
        eula_payload=$(envsubst < ${templates_dir_path}/eula.json)
        make_initial_api_request -s -X PUT \
            -d "${eula_payload}" \
            "${PINGACCESS_ADMIN_API_ENDPOINT}/users/1" > /dev/null
        test $? -ne 0 && exit 1

        beluga_log "Changing the default password..."
        beluga_log "Change password debugging output suppressed"

        changePassword

        # Export CONFIG_QUERY_KP_VALID_DAYS so it will get injected into
        # config-query-keypair.json.  Default to 365 days.
        export CONFIG_QUERY_KP_VALID_DAYS=${CONFIG_QUERY_KP_VALID_DAYS:-365}

        beluga_log "Check to see if the Config Query Keypair already exists..."

        # Export CONFIG_QUERY_KP_ALIAS so it will get injected into
        # config-query-keypair.json.
        export CONFIG_QUERY_KP_ALIAS='pingaccess-config-query'
        get_config_query_keypair_response=$(make_api_request -s "${PINGACCESS_ADMIN_API_ENDPOINT}/keyPairs")
        test $? -ne 0 && exit 1

        config_query_keypair=$(jq -n "${get_config_query_keypair_response}" \
            | jq --arg cq_kp_alias "${CONFIG_QUERY_KP_ALIAS}" '.items[] | select(.alias == $cq_kp_alias)')
        config_query_keypair_alias=$(jq -n "${config_query_keypair}" | jq -r '.alias')


        # Check to see if the keypair already exists.  This can happen if the
        # s3 bucket already has configuration in it and the restore runs
        # before reaching this script.  The s3 bucket should be clean when
        # this runs in production.  Here we're not changing any of the
        # configuration in case developers aren't cleaning their buckets out.
        # In that case, this script shouldn't change an existing config.
        if [ "${config_query_keypair_alias}" = 'null' ]; then

            # Generate a new keypair for the config query listener
            beluga_log "Creating a Config Query KeyPair..."
            config_query_keypair_payload=$(envsubst < ${templates_dir_path}/config-query-keypair.json)
            create_config_query_keypair_response=$(make_api_request -s -d \
                "${config_query_keypair_payload}" \
                "${PINGACCESS_ADMIN_API_ENDPOINT}/keyPairs/generate")
            test $? -ne 0 && exit 1

            # Export CONFIG_QUERY_KEYPAIR_ID so it will get injected into
            # config-query.json.
            export CONFIG_QUERY_KEYPAIR_ID=$(jq -n "${create_config_query_keypair_response}" | jq '.id')

            # Retrieving CONFIG QUERY id
            https_listeners_response=$(make_api_request -s "${PINGACCESS_ADMIN_API_ENDPOINT}/httpsListeners")
            test $? -ne 0 && exit 1

            config_query_listener_id=$(jq -n "${https_listeners_response}" | jq '.items[] | select(.name=="CONFIG QUERY") | .id')

            # Update CONFIG QUERY HTTPS Listener with with the new keypair
            beluga_log "Updating the Config Query HTTPS Listener with the new KeyPair id..."
            config_query_payload=$(envsubst < ${templates_dir_path}/config-query.json)
            config_query_response=$(make_api_request -s -X PUT \
                -d "${config_query_payload}" \
                "${PINGACCESS_ADMIN_API_ENDPOINT}/httpsListeners/${config_query_listener_id}")
            test $? -ne 0 && exit 1

         else

            beluga_log "Keypair ${CONFIG_QUERY_KP_ALIAS} already exists.  Skipping configuration of the Keypair, the Config Query HTTPS Listener, and the Admin Config."

         fi
    else
        beluga_log "PingAccess has already been configured.  Exiting without making configuration changes."
    fi

else
     beluga_log "Received a ${http_response_code} when checking the user endpoint.  Exiting without making configuration changes."
fi

exit 0
