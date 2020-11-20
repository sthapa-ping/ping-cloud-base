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

testGenerateKeypairHappyPath() {
    response=$(generate_keypair "${templates_dir_path}/config-query.json")
    assertEquals "Given the mocked function in this test file and the input parameters, this test should succeed" 0 $?
}

# load shunit
. ${SHUNIT_PATH}