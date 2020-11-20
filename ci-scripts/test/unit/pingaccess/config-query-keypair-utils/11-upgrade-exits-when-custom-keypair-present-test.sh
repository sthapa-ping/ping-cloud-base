#!/bin/bash

# Source support libs referenced by the tested script
. "${PROJECT_DIR}"/profiles/aws/pingaccess/hooks/utils.lib.sh

# Source the script we're testing
script_to_test="${PROJECT_DIR}"/profiles/aws/pingaccess/hooks/util/config-query-keypair-utils.sh
. "${script_to_test}"

readonly resources_dir="${PROJECT_DIR}"/ci-scripts/test/unit/pingaccess/config-query-keypair-utils/resources

# mock calls to config-query-keypair-utils
get_config_query_keypair_id() {
    echo 5
}

get_keypair_by_id() {
    keypair=$(cat "${resources_dir}"/non-hook-script-generated-keypair.json)
    echo "${keypair}"
}

# Admins may have changed the generated 'pingaccess-config-query' keypair
# to something else.  In that case, the logic should safeguard this keypair
# and exit without making any changes.
testUpgradeExitsWhenCustomKeypairPresent() {
    local templates_dir_path="${PROJECT_DIR}"/profiles/aws/pingaccess/templates/81
    logs=$(upgrade_config_query_listener_keypair "${templates_dir_path}")
    assertEquals "The function upgrade_config_query_listener_keypair should have exited with a 0." 0 $?

    # Look for the message indicating the upgrade was skipped
    message="The Keypair on the Config Query HTTPS Listener does not match the default.  Skipping the Config Query Keypair upgrade."
    assertContains "Given the mock functions in this test, the alias in the keypair should not have matched 'pingaccess-config-query'" "${logs}" "${message}"
}

# load shunit
. ${SHUNIT_PATH}



