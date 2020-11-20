#!/bin/bash

# Source the script we're testing
script_to_test="${PROJECT_DIR}"/profiles/aws/pingaccess/hooks/util/config-query-keypair-utils.sh
. "${script_to_test}"

readonly resources_dir="${PROJECT_DIR}"/ci-scripts/test/unit/pingaccess/config-query-keypair-utils/resources

# mock the api call
make_api_request() {
    https_listeners_response=$(cat "${resources_dir}"/https-listeners-items.json)
    echo "${https_listeners_response}"
}

testGetConfigQueryKeypairIdHappyPath() {
    id=$(get_config_query_keypair_id)
    assertEquals "The keyPairId for CONFIG QUERY in https-listeners-items.json should be 6" 6 ${id}
}

# load shunit
. ${SHUNIT_PATH}