#!/bin/bash

##### ----- READ BEFORE RUNNING THE SCRIPT ----- #####

# The following script shows how to seal all the secrets used by ping apps and their supporting cluster tools.
# It requires kustomize and kubeseal to be installed.

# It is recommended that all (instead of a subset) of the secrets be sealed at the same time. This ensures that they
# are all encrypted with the same sealing key. After sealing the secrets, make sure to save off the Bitnami service's
# master key using PingCloud docs.

# Before running this script, populate all the required secrets in the ping-cloud and cluster-tools secret.yaml files.
# A copy of the original contents of the secrets.yaml file is available in both the ping-cloud and cluster-tools
# directories. The script intentionally does not replace any files in the cluster state repo because it can be
# destructive. Instead, it prints out the steps required to seal secrets for the DevOps engineer to apply manually.


SCRIPT_DIR=$(cd $(dirname "${0}"); pwd)
pushd "${SCRIPT_DIR}" &> /dev/null

########################################################################################################################
# Verify that the provided binaries are available.
#
# Arguments
#   ${*} -> The list of required binaries.
########################################################################################################################
check_binaries() {
  STATUS=0
  for TOOL in ${*}; do
    which "${TOOL}" &>/dev/null
    if test ${?} -ne 0; then
      echo "${TOOL} is required but missing"
      STATUS=1
    fi
  done
  return ${STATUS}
}

########################################################################################################################
# Prints script usage.
########################################################################################################################
usage() {
  echo "Usage: ./seal.sh [<CERT_FILE>]"
  echo
  echo "  CERT_FILE  - a file containing the PEM-encoded encryption key, i.e. the public key of the sealed secrets"
  echo "               controller. If the CERT_FILE is not provided, then kubeseal will be run against the current"
  echo "               cluster to try to obtain the public key of the sealed secrets controller running on it."
  echo
  echo "Example: ./seal.sh /tmp/encryption.key"
}

####################
#   Start script   #
####################

# Check for required binaries.
check_binaries "kustomize" "kubeseal"
HAS_REQUIRED_TOOLS=${?}
test ${HAS_REQUIRED_TOOLS} -ne 0 && exit 1

CERT_FILE="$1"
BUILD_DIR="${BUILD_DIR:-base}"
UPDATE_MANIFESTS="${UPDATE_MANIFESTS:-false}"
QUIET="${QUIET:-false}"

if ! "${QUIET}"; then
  echo "---------------------------------------------------------------------------------------------------------------"
  echo "Read the 'READ BEFORE RUNNING THE SCRIPT' section at the top of this script"
  echo "---------------------------------------------------------------------------------------------------------------"
fi

# Run flux-command.sh with an OUT_DIR so each k8s resource is written to a separate file. Also, give it a fake
# REGION_NICK_NAME and TENANT_DOMAIN because all secrets exist in base, and without these variables, "kustomize build"
# will fail when invoked from within flux-command.sh.
OUT_DIR=$(mktemp -d)
OUT_DIR="${OUT_DIR}" REGION_NICK_NAME=base TENANT_DOMAIN=base.ping-cloud.com \
    "${SCRIPT_DIR}"/flux-command.sh "${BUILD_DIR}"

YAML_FILES=$(find "${OUT_DIR}" -type f | xargs grep -rl 'kind: Secret')
if test -z "${YAML_FILES}"; then
  echo "No secrets found to seal"
  exit 0
fi

# If the certificate file is not provided, try to get the certificate from the Bitnami sealed secret service.
# The sealed-secrets controller must be running in the cluster, and it should be possible to access the Kubernetes
# API server for this to work.
if test -z "${CERT_FILE}"; then
  CERT_FILE=$(mktemp)
  echo "Fetching the sealed secret certificate from the current cluster context"
  kubeseal --fetch-cert --controller-namespace kube-system > "${CERT_FILE}"
fi

if ! "${QUIET}"; then
  echo "---------------------------------------------------------------------------------------------------------------"
  echo "WARNING!!! Ensure that ${CERT_FILE} contains the public key of the Bitnami sealed secret service running in    "
  echo "your cluster. It may be obtained by running the following command on the management node:"
  echo
  echo "kubeseal --fetch-cert --controller-namespace kube-system"
  echo "---------------------------------------------------------------------------------------------------------------"
fi

echo "Using certificate file ${CERT_FILE} for encrypting secrets"

SEALED_SECRETS_FILE=/tmp/sealed-secrets.yaml
rm -f "${SEALED_SECRETS_FILE}"

SECRETS_FILE=/tmp/ping-secrets.yaml
rm -f "${SECRETS_FILE}"

for FILE in ${YAML_FILES}; do
  NAME=$(grep '^  name:' "${FILE}" | cut -d: -f2 | tr -d '[:space:]')
  NAMESPACE=$(grep '^  namespace:' "${FILE}" | cut -d: -f2 | tr -d '[:space:]')

  cat >> "${SECRETS_FILE}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
\$patch: delete

---

EOF

  # Only seal secrets that have data in them.
  if grep '^data' "${FILE}" &> /dev/null; then
    echo "Creating sealed secret for \"${NAMESPACE}:${NAME}\""

    # Append the sealed secret to the sealed secrets file.
    kubeseal --cert "${CERT_FILE}" -o yaml --allow-empty-data < "${FILE}" >> "${SEALED_SECRETS_FILE}"
    echo --- >> "${SEALED_SECRETS_FILE}"
    echo >> "${SEALED_SECRETS_FILE}"

    # Replace ping-cloud-* namespace to just ping-cloud because it is the default in the kustomization base.
    echo -n "${NAMESPACE}" | grep '^ping-cloud' &> /dev/null && NAMESPACE=ping-cloud
  else
    echo "Not creating sealed secret for \"${NAMESPACE}:${NAME}\" because it doesn't have any data"
  fi
done

if "${UPDATE_MANIFESTS}"; then
  test -f "${SECRETS_FILE}" && cp "${SECRETS_FILE}" "${BUILD_DIR}/secrets.yaml"
  test -f "${SEALED_SECRETS_FILE}" && cp "${SEALED_SECRETS_FILE}" "${BUILD_DIR}/sealed-secrets.yaml"
else
  echo
  echo '------------------------'
  echo '|  Next steps to take  |'
  echo '------------------------'
  echo "- Run the following commands from the k8s-configs directory:"
  echo "      cd k8s-configs"
  echo "      test -f ${SECRETS_FILE} && cp ${SECRETS_FILE} ${BUILD_DIR}/secrets.yaml"
  echo "      test -f ${SEALED_SECRETS_FILE} && cp ${SEALED_SECRETS_FILE} ${BUILD_DIR}/sealed-secrets.yaml"
  echo "      ./flux-command.sh \${REGION_DIR} > /tmp/deploy.yaml"
  echo "      grep 'kind: Secret' /tmp/deploy.yaml # should not have any hits"
  echo "      grep 'kind: SealedSecret' /tmp/deploy.yaml # should have hits"
  echo "- Push all modified files into the cluster state repo"
  echo "- Run this script for each CDE branch and region directory in the order - dev, test, stage, prod"
  echo "- IMPORTANT: create a backup of the Bitnami service's master key using PingCloud docs"
fi

popd &> /dev/null