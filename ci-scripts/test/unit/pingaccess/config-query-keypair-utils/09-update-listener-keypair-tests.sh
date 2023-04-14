#!/bin/bash

# Source support libs referenced by the tested script
. "${PROJECT_DIR}"/profiles/aws/pingaccess/hooks/utils.lib.sh

# Source the script we're testing
script_to_test="${PROJECT_DIR}"/profiles/aws/pingaccess/hooks/util/config-query-keypair-utils.sh
. "${script_to_test}"

templates_dir_path="${PROJECT_DIR}"/profiles/aws/pingaccess/templates/81

make_api_request() {
    exit 0
}

testUpdateListenerKeypairHappyPath() {
    keypair_id=1
    config_query_listener_id=4
    response=$(update_listener_keypair ${keypair_id} ${config_query_listener_id} "${templates_dir_path}/config-query.json")
    return_code=$?

    assertEquals "The call to update_listener_keypair had had all of the required parameters.  The return_code should be 0" 0 ${return_code}
    message="Updating the Config Query HTTPS Listener ${config_query_listener_id} with the new KeyPair id: ${keypair_id}"
    assertContains "The message have contained a keypair_id of ${keypair_id} and a config_query_listener_id of ${config_query_listener_id}" "${response}" "${message}"
}

testUpdateListenerKeypairMissingKeypairId() {
    response=$(update_listener_keypair)
    return_code=$?

    assertEquals "The call to update_listener_keypair was missing input parameters.  The return_code should be 1" 1 ${return_code}
    message="keypair_id is required but was not passed in as a parameter"
    assertContains "Calling this script without the required parameters should fail" "${response}" "${message}"
}

# load shunit
. ${SHUNIT_PATH}