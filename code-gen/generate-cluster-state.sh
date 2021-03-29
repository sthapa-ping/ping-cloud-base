#!/bin/bash

# If VERBOSE is true, then output line-by-line execution
"${VERBOSE:-false}" && set -x

########################################################################################################################
#
# Note: This script must be executed within its git checkout tree after switching to the desired branch.
#
# This script may be used to generate the initial Kubernetes configurations to push into the cluster-state repository
# for a particular tenant. This repo is referred to as the cluster state repo because the EKS clusters are always
# (within a few minutes) reflective of the code in this repo. This repo is the only interface for updates to the
# clusters. In other words, kubectl commands that alter the state of the cluster are verboten outside of this repo.
#
# The intended audience of this repo is primarily the Ping Professional Services and Support team, with limited access
# granted to Customer administrators. These users may further tweak the cluster state per the tenant's requirements.
# They are expected to have an understanding of Kubernetes manifest files and kustomize, a client-side tool used to make
# further customizations to the initial state generated by this script.
#
# The script generates Kubernetes manifest files for 4 different environments - dev, test, stage and prod. The
# manifest files for these environments contain deployments of both the Ping Cloud stack and the supporting tools
# necessary to provide an end-to-end solution.
#
# For example, the script produces a directory structure as shown below (Directories greater than a depth of 3 and
# files within the directories are omitted for brevity):
#
# ├── cluster-state
# │  └── k8s-configs
# │     ├── dev
# │     ├── prod
# │     ├── stage
# │     └── test
# │  └── profiles
# └── fluxcd
#    ├── dev
#    ├── prod
#    ├── stage
#    └── test
#
# Deploying the manifests under the fluxcd directory for a specific environment will bootstrap the cluster with a
# Continuous Delivery tool. Once the CD tool is deployed to the cluster, it will deploy the rest of the ping stack
# and supporting tools for that environment.
#
# ------------
# Requirements
# ------------
# The script requires the following tools to be installed:
#   - openssl
#   - ssh-keygen
#   - ssh-keyscan
#   - base64
#   - envsubst
#   - git
#
# ------------------
# Usage instructions
# ------------------
# The script does not take any parameters, but rather acts on environment variables. The environment variables will
# be substituted into the variables in the yaml template files. The following mandatory environment variables must be
# present before running this script:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable                    | Purpose
# ----------------------------------------------------------------------------------------------------------------------
# PING_IDENTITY_DEVOPS_USER   | A user with license to run Ping Software
# PING_IDENTITY_DEVOPS_KEY    | The key to the above user
#
# In addition, the following environment variables, if present, will be used for the following purposes:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable                 | Purpose                                            | Default (if not present)
# ----------------------------------------------------------------------------------------------------------------------
# TENANT_NAME              | The name of the tenant, e.g. k8s-icecream. If      | First segment of the TENANT_DOMAIN
#                          | provided, this value will be used for the cluster  | value. E.g. it will default to "ci-cd" 
#                          | name and must have the correct case (e.g. ci-cd    | for tenant domain "ci-cd.ping-oasis.com"
#                          | vs. CI-CD).                                        |
#                          |                                                    |
# TENANT_DOMAIN            | The tenant's domain suffix that's common to all    | ci-cd.ping-oasis.com
#                          | CDEs e.g. k8s-icecream.com. The tenant domain in   |
#                          | each CDE is assumed to have the CDE name as the    |
#                          | prefix, followed by a hyphen. For example, for the |
#                          | above suffix, the tenant domain for stage is       |
#                          | assumed to be stage-k8s-icecream.com and a hosted  |
#                          | zone assumed to exist on Route53 for that domain.  |
#                          |                                                    |
# GLOBAL_TENANT_DOMAIN     | Region-independent URL used for DNS failover/      | Replaces the first segment of
#                          | routing.                                           | the TENANT_DOMAIN value with the
#                          |                                                    | string "global". For example, it will
#                          |                                                    | default to "global.poc.ping.com" for
#                          |                                                    | tenant domain "us1.poc.ping.cloud".
#                          |                                                    |
# SECONDARY_TENANT_DOMAINS | A comma-separated list of tenant domain suffixes   | No default.
#                          | of secondary regions in multi-region environments, |
#                          | e.g. "xxx.eu1.ping.cloud,xxx.au1.ping.cloud".      |
#                          | The primary tenant domain suffix must not be in    |
#                          | the list. Only used if IS_MULTI_CLUSTER is true.   |
#                          |                                                    |
# REGION                   | The region where the tenant environment is         | us-west-2
#                          | deployed. For PCPT, this is a required parameter   |
#                          | to Container Insights, an AWS-specific logging     |
#                          | and monitoring solution.                           |
#                          |                                                    |
# REGION_NICK_NAME         | An optional nick name for the region. For example, | Same as REGION.
#                          | this variable may be set to a unique name in       |
#                          | multi-cluster deployments which live in the same   |
#                          | region. The nick name will be used as the name of  |
#                          | the region-specific code directory in the cluster  |
#                          | state repo.                                        |
#                          |                                                    |
# IS_MULTI_CLUSTER         | Flag indicating whether or not this is a           | false
#                          | multi-cluster deployment.                          |
#                          |                                                    |
# PRIMARY_TENANT_DOMAIN    | In multi-cluster environments, the primary domain. | Same as TENANT_DOMAIN.
#                          | Only used if IS_MULTI_CLUSTER is true.             |
#                          |                                                    |
# PRIMARY_REGION           | In multi-cluster environments, the primary region. | Same as REGION.
#                          | Only used if IS_MULTI_CLUSTER is true.             |
#                          |                                                    |
# CLUSTER_BUCKET_NAME      | The optional name of the S3 bucket where cluster   | No default.
#                          | information is maintained for PF. Only used if     |
#                          | IS_MULTI_CLUSTER is true. If provided, PF will be  |
#                          | configured with NATIVE_S3_PING discovery and will  |
#                          | precede over DNS_PING, which is always configured. |
#                          |                                                    |
# SIZE                     | Size of the environment, which pertains to the     | x-small
#                          | number of user identities. Legal values are        |
#                          | x-small, small, medium or large.                   |
#                          |                                                    |
# CLUSTER_STATE_REPO_URL   | The URL of the cluster-state repo.                 | https://github.com/pingidentity/ping-cloud-base
#                          |                                                    |
# ARTIFACT_REPO_URL        | The URL for plugins (e.g. PF kits, PD extensions). | The string "unused".
#                          | If not provided, the Ping stack will be            |
#                          | provisioned without plugins. This URL must always  |
#                          | have an s3 scheme, e.g.                            |
#                          | s3://customer-repo-bucket-name.                    |
#                          |                                                    |
# PING_ARTIFACT_REPO_URL   | This environment variable can be used to overwrite | https://ping-artifacts.s3-us-west-2.amazonaws.com
#                          | the default endpoint for public plugins. This URL  |
#                          | must use an https scheme as shown by the default   |
#                          | value.                                             |
#                          |                                                    |
# LOG_ARCHIVE_URL          | The URL of the log archives. If provided, logs are | The string "unused".
#                          | periodically captured and sent to this URL. For    |
#                          | AWS S3 buckets, it must be an S3 URL, e.g.         |
#                          | s3://logs.                                         |
#                          |                                                    |
# BACKUP_URL               | The URL of the backup location. If provided, data  | The string "unused".
#                          | backups are periodically captured and sent to this |
#                          | URL. For AWS S3 buckets, it must be an S3 URL,     |
#                          | e.g. s3://backups.                                 |
#                          |                                                    |
# K8S_GIT_URL              | The Git URL of the Kubernetes base manifest files. | https://github.com/pingidentity/ping-cloud-base
#                          |                                                    |
# K8S_GIT_BRANCH           | The Git branch within the above Git URL.           | The git branch where this script
#                          |                                                    | exists, i.e. CI_COMMIT_REF_NAME
#                          |                                                    |
# SSH_ID_PUB_FILE          | The file containing the public-key (in PEM format) | No default
#                          | used by the CD tool and Ping containers to access  |
#                          | the cluster state and config repos, respectively.  |
#                          | If not provided, a new key-pair will be generated  |
#                          | by the script. If provided, the SSH_ID_KEY_FILE    |
#                          | must also be provided and correspond to this       |
#                          | public key.                                        |
#                          |                                                    |
# SSH_ID_KEY_FILE          | The file containing the private-key (in PEM        | No default
#                          | format) used by the CD tool and Ping containers to |
#                          | access the cluster state and config repos,         |
#                          | respectively. If not provided, a new key-pair      |
#                          | will be generated by the script. If provided, the  |
#                          | SSH_ID_PUB_FILE must also be provided and          |
#                          | correspond to this private key.                    |
#                          |                                                    |
# TARGET_DIR               | The directory where the manifest files will be     | /tmp/sandbox
#                          | generated. If the target directory exists, it will |
#                          | be deleted.                                        |
#                          |                                                    |
# IS_BELUGA_ENV            | An optional flag that may be provided to indicate  | false. Only intended for Beluga
#                          | that the cluster state is being generated for      | developers.
#                          | testing during Beluga development. If set to true, |
#                          | the cluster name is assumed to be the tenant name  |
#                          | and the tenant domain assumed to be the same       |
#                          | across all 4 CDEs. On the other hand, in PCPT, the |
#                          | cluster name for the CDEs are hardcoded to dev,    |
#                          | test, stage and prod. The domain names for the     |
#                          | CDEs are derived from the TENANT_DOMAIN variable   |
#                          | as documented above. This flag exists because the  |
#                          | Beluga developers only have access to one domain   |
#                          | and hosted zone in their Ping IAM account role.    |
#                          |                                                    |
# ACCOUNT_ID_PATH_PREFIX   | The SSM path prefix which stores CDE account IDs   | The string "unused".
#                          | of the Ping Cloud customers. The environment type  |
#                          | is appended to the key path before the value is    |
#                          | retrieved from the SSM endpoint. The IAM role with |
#                          | the AWS account ID must be added as an annotation  |
#                          | to the corresponding Kubernetes service account to |
#                          | enable IRSA (IAM Role for Service Accounts).       |
#                          |                                                    |
# NLB_EIP_PATH_PREFIX      | The SSM path prefix which stores comma seperated   | The string "unused".
#                          | AWS Elastic IP allocation IDs that exists in the   |
#                          | CDE account of the Ping Cloud customers.           |
#                          | The environment type is appended to the SSM key    | 
#                          | path before the value is retrieved from the        |
#                          | AWS SSM endpoint. The EIP allocation IDs must be   |
#                          | added as an annotation to the corresponding K8s    |
#                          | service for the AWS NLB to use the AWS Elastic IP. |
#                          |                                                    |
# EVENT_QUEUE_NAME         | The name of the queue that may be used to notify   | platform_event_queue.fifo
#                          | PingCloud applications of platform events. This    |
#                          | is currently only used if the orchestrator for     |
#                          | PingCloud environments is MyPing.                  |
#                          |                                                    |
# NEW_RELIC_LICENSE_KEY    | The key of NewRelic APM Agent used to send data to | The string "unused".
#                          | NewRelic account                                   |
########################################################################################################################

#### SCRIPT START ####

# Ensure that this script works from any working directory.
SCRIPT_HOME=$(cd $(dirname ${0}) 2>/dev/null; pwd)
pushd "${SCRIPT_HOME}" >/dev/null 2>&1

# Quiet mode where instructional messages are omitted.
QUIET="${QUIET:-false}"

# Source some utility methods.
. ../utils.sh

# Source aws specific utility methods.
. ./aws/utils.sh

########################################################################################################################
# Substitute variables in all template files in the provided directory.
#
# Arguments
#   ${1} -> The directory that contains the template files.
########################################################################################################################

# The list of variables in the template files that will be substituted by default.
# Note: only secret variables are substituted into YAML files. Environments variables are just written to an env_vars
# file and substituted at runtime by the continuous delivery tool running in cluster.
DEFAULT_VARS='${PING_IDENTITY_DEVOPS_USER_BASE64}
${PING_IDENTITY_DEVOPS_KEY_BASE64}
${NEW_RELIC_LICENSE_KEY_BASE64}
${TENANT_NAME}
${SSH_ID_KEY_BASE64}
${IS_MULTI_CLUSTER}
${CLUSTER_BUCKET_NAME}
${EVENT_QUEUE_NAME}
${REGION}
${REGION_NICK_NAME}
${PRIMARY_REGION}
${TENANT_DOMAIN}
${PRIMARY_TENANT_DOMAIN}
${SECONDARY_TENANT_DOMAINS}
${GLOBAL_TENANT_DOMAIN}
${ARTIFACT_REPO_URL}
${PING_ARTIFACT_REPO_URL}
${LOG_ARCHIVE_URL}
${BACKUP_URL}
${PING_CLOUD_NAMESPACE}
${K8S_GIT_URL}
${K8S_GIT_BRANCH}
${REGISTRY_NAME}
${KNOWN_HOSTS_CLUSTER_STATE_REPO}
${CLUSTER_STATE_REPO_URL}
${CLUSTER_STATE_REPO_BRANCH}
${CLUSTER_STATE_REPO_PATH_DERIVED}
${SERVER_PROFILE_URL_DERIVED}
${SERVER_PROFILE_BRANCH_DERIVED}
${SERVER_PROFILE_PATH}
${ENV}
${ENVIRONMENT_TYPE}
${KUSTOMIZE_BASE}
${LETS_ENCRYPT_SERVER}
${PF_PD_BIND_PORT}
${PF_PD_BIND_PROTOCOL}
${PF_PD_BIND_USESSL}
${PF_MIN_HEAP}
${PF_MAX_HEAP}
${PF_MIN_YGEN}
${PF_MAX_YGEN}
${PA_WAS_MIN_HEAP}
${PA_WAS_MAX_HEAP}
${PA_WAS_MIN_YGEN}
${PA_WAS_MAX_YGEN}
${PA_WAS_GCOPTION}
${PA_MIN_HEAP}
${PA_MAX_HEAP}
${PA_MIN_YGEN}
${PA_MAX_YGEN}
${PA_GCOPTION}
${CLUSTER_NAME}
${CLUSTER_NAME_LC}
${DNS_ZONE}
${DNS_ZONE_DERIVED}
${PRIMARY_DNS_ZONE}
${PRIMARY_DNS_ZONE_DERIVED}
${PINGACCESS_IMAGE_TAG}
${PINGFEDERATE_IMAGE_TAG}
${PINGDIRECTORY_IMAGE_TAG}
${PINGDELEGATOR_IMAGE_TAG}
${LAST_UPDATE_REASON}
${IRSA_PING_ANNOTATION_KEY_VALUE}
${NLB_PD_ADMIN_ANNOTATION_KEY_VALUE}
${NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE}
${NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE}'

# Variables to replace within the generated cluster state code
REPO_VARS="${REPO_VARS:-${DEFAULT_VARS}}"

# Variables to replace in the generated bootstrap code
BOOTSTRAP_VARS='${K8S_GIT_URL}
${K8S_GIT_BRANCH}
${CLUSTER_STATE_REPO_URL}
${CLUSTER_STATE_REPO_BRANCH}
${REGION_NICK_NAME}
${PING_CLOUD_NAMESPACE}
${KNOWN_HOSTS_CLUSTER_STATE_REPO}
${SSH_ID_KEY_BASE64}'

########################################################################################################################
# Export some derived environment variables.
########################################################################################################################
add_derived_variables() {
  # The directory within the cluster state repo for the region's manifest files.
  export CLUSTER_STATE_REPO_PATH_DERIVED="\${REGION_NICK_NAME}"

  # Server profile URL and branch. The directory is in each app's env_vars file.
  export SERVER_PROFILE_URL_DERIVED="\${CLUSTER_STATE_REPO_URL}"
  export SERVER_PROFILE_BRANCH_DERIVED="\${CLUSTER_STATE_REPO_BRANCH}"

  # Zone for this region and the primary region.
  export DNS_ZONE_DERIVED="\${DNS_ZONE}"
  export PRIMARY_DNS_ZONE_DERIVED="\${PRIMARY_DNS_ZONE}"
}

########################################################################################################################
# Export IRSA annotation for the provided environment.
#
# Arguments
#   ${1} -> The SSM path prefix which stores CDE account IDs of Ping Cloud environments.
#   ${2} -> The environment name.
########################################################################################################################
add_irsa_variables() {
  if test "${IRSA_PING_ANNOTATION_KEY_VALUE}"; then
    export IRSA_PING_ANNOTATION_KEY_VALUE="${IRSA_PING_ANNOTATION_KEY_VALUE}"
    return
  fi

  local ssm_path_prefix="$1"
  local env="$2"

  # Default empty string
  IRSA_PING_ANNOTATION_KEY_VALUE=''

  if [ "${ssm_path_prefix}" != "unused" ]; then

    # Getting value from ssm parameter store.
    if ! ssm_value=$(get_ssm_value "${ssm_path_prefix}/${env}"); then
      echo "Error: ${ssm_value}"
      exit 1
    fi

    # IRSA for ping product pods. The role name is predefined as a part of the interface contract.
    IRSA_PING_ANNOTATION_KEY_VALUE="eks.amazonaws.com/role-arn: arn:aws:iam::${ssm_value}:role/pcpt/irsa-roles/irsa-ping"
  fi

  export IRSA_PING_ANNOTATION_KEY_VALUE="${IRSA_PING_ANNOTATION_KEY_VALUE}"
}

########################################################################################################################
# Export NLB EIP annotation for the provided environment.
#
# Arguments
#   ${1} -> The SSM path prefix which stores CDE account IDs of Ping Cloud environments.
#   ${2} -> The environment name.
########################################################################################################################
add_nlb_variables() {
  local ssm_path_prefix="$1"
  local env="$2"

  if test "${NLB_PD_ADMIN_ANNOTATION_KEY_VALUE}"; then
    export NLB_PD_ADMIN_ANNOTATION_KEY_VALUE="${NLB_PD_ADMIN_ANNOTATION_KEY_VALUE}"
  else
    # Default empty string
    NLB_PD_ADMIN_ANNOTATION_KEY_VALUE=''

    if [ "${ssm_path_prefix}" != "unused" ]; then

      # Getting value from ssm parameter store.
      if ! ssm_value=$(get_ssm_value "${ssm_path_prefix}/${env}/elastic-ips/nlb/pingdirectory-admin"); then
        echo "Error: ${ssm_value}"
        exit 1
      fi

      NLB_PD_ADMIN_ANNOTATION_KEY_VALUE="service.beta.kubernetes.io/aws-load-balancer-eip-allocations: ${ssm_value}"
    fi

    export NLB_PD_ADMIN_ANNOTATION_KEY_VALUE="${NLB_PD_ADMIN_ANNOTATION_KEY_VALUE}"
  fi

  if test "${NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE}"; then
    export NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE="${NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE}"
  else
    # Default empty string
    NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE=''

    if [ "${ssm_path_prefix}" != "unused" ]; then

      # Getting value from ssm parameter store.
      if ! ssm_value=$(get_ssm_value "${ssm_path_prefix}/${env}/elastic-ips/nlb/nginx-public"); then
        echo "Error: ${ssm_value}"
        exit 1
      fi

      NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE="service.beta.kubernetes.io/aws-load-balancer-eip-allocations: ${ssm_value}"
    fi

    export NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE="${NLB_NGX_PUBLIC_ANNOTATION_KEY_VALUE}"
  fi

  if test "${NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE}"; then
    export NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE="${NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE}"
  else
    # Default empty string
    NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE=''

    if [ "${ssm_path_prefix}" != "unused" ]; then

      # Getting value from ssm parameter store.
      if ! ssm_value=$(get_ssm_value "${ssm_path_prefix}/${env}/elastic-ips/nlb/nginx-private"); then
        echo "Error: ${ssm_value}"
        exit 1
      fi

      NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE="service.beta.kubernetes.io/aws-load-balancer-eip-allocations: ${ssm_value}"
    fi

    export NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE="${NLB_NGX_PRIVATE_ANNOTATION_KEY_VALUE}"
  fi
}

# Checking required tools and environment variables.
check_binaries "openssl" "ssh-keygen" "ssh-keyscan" "base64" "envsubst" "git" "aws"
HAS_REQUIRED_TOOLS=${?}

check_env_vars "PING_IDENTITY_DEVOPS_USER" "PING_IDENTITY_DEVOPS_KEY"
HAS_REQUIRED_VARS=${?}

if test ${HAS_REQUIRED_TOOLS} -ne 0 || test ${HAS_REQUIRED_VARS} -ne 0; then
  # Go back to previous working directory, if different, before exiting.
  popd >/dev/null 2>&1
  exit 1
fi

if test -z "${IS_MULTI_CLUSTER}"; then
  IS_MULTI_CLUSTER=false
fi

if "${IS_MULTI_CLUSTER}"; then
  if test ! "${CLUSTER_BUCKET_NAME}" && test ! "${SECONDARY_TENANT_DOMAINS}"; then
    echo 'In multi-cluster mode, one or both of CLUSTER_BUCKET_NAME and SECONDARY_TENANT_DOMAINS must be set.'
    popd >/dev/null 2>&1
    exit 1
  fi
fi

# Print out the values provided used for each variable.
echo "Initial TENANT_NAME: ${TENANT_NAME}"
echo "Initial SIZE: ${SIZE}"

echo "Initial IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
echo "Initial CLUSTER_BUCKET_NAME: ${CLUSTER_BUCKET_NAME}"
echo "Initial EVENT_QUEUE_NAME: ${EVENT_QUEUE_NAME}"
echo "Initial REGION: ${REGION}"
echo "Initial REGION_NICK_NAME: ${REGION_NICK_NAME}"
echo "Initial PRIMARY_REGION: ${PRIMARY_REGION}"
echo "Initial TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Initial GLOBAL_TENANT_DOMAIN: ${GLOBAL_TENANT_DOMAIN}"
echo "Initial PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"
echo "Initial SECONDARY_TENANT_DOMAINS: ${SECONDARY_TENANT_DOMAINS}"

echo "Initial CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"

echo "Initial ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Initial PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"

echo "Initial LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
echo "Initial BACKUP_URL: ${BACKUP_URL}"

echo "Initial K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Initial K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

echo "Initial SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE}"
echo "Initial SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE}"

echo "Initial TARGET_DIR: ${TARGET_DIR}"
echo "Initial IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

# Use defaults for other variables, if not present.
export IS_BELUGA_ENV="${IS_BELUGA_ENV:-false}"
export TENANT_NAME="${TENANT_NAME:-${TENANT_DOMAIN%%.*}}"
export SIZE="${SIZE:-x-small}"

### Region-specific environment variables ###
export REGION="${REGION}"
export REGION_NICK_NAME="${REGION_NICK_NAME:-${REGION}}"

TENANT_DOMAIN_NO_DOT_SUFFIX="${TENANT_DOMAIN%.}"
export TENANT_DOMAIN="${TENANT_DOMAIN_NO_DOT_SUFFIX}"

export CLUSTER_BUCKET_NAME="${CLUSTER_BUCKET_NAME}"
export EVENT_QUEUE_NAME=${EVENT_QUEUE_NAME:-platform_event_queue.fifo}
export ARTIFACT_REPO_URL="${ARTIFACT_REPO_URL:-unused}"

export LAST_UPDATE_REASON="${LAST_UPDATE_REASON:-NA}"

### Base environment variables ###
export IS_MULTI_CLUSTER="${IS_MULTI_CLUSTER}"

export PRIMARY_REGION="${PRIMARY_REGION:-${REGION}}"
PRIMARY_TENANT_DOMAIN_NO_DOT_SUFFIX="${PRIMARY_TENANT_DOMAIN%.}"
export PRIMARY_TENANT_DOMAIN="${PRIMARY_TENANT_DOMAIN_NO_DOT_SUFFIX:-${TENANT_DOMAIN_NO_DOT_SUFFIX}}"
export SECONDARY_TENANT_DOMAINS="${SECONDARY_TENANT_DOMAINS}"

if "${IS_BELUGA_ENV}"; then
  DERIVED_GLOBAL_TENANT_DOMAIN="global.${TENANT_DOMAIN_NO_DOT_SUFFIX}"
else
  DERIVED_GLOBAL_TENANT_DOMAIN="$(echo "${TENANT_DOMAIN_NO_DOT_SUFFIX}" | sed -e "s/\([^.]*\).[^.]*.\(.*\)/global.\1.\2/")"
fi
GLOBAL_TENANT_DOMAIN_NO_DOT_SUFFIX="${GLOBAL_TENANT_DOMAIN%.}"
export GLOBAL_TENANT_DOMAIN="${GLOBAL_TENANT_DOMAIN_NO_DOT_SUFFIX:-${DERIVED_GLOBAL_TENANT_DOMAIN}}"

export PING_ARTIFACT_REPO_URL="${PING_ARTIFACT_REPO_URL:-https://ping-artifacts.s3-us-west-2.amazonaws.com}"

export LOG_ARCHIVE_URL="${LOG_ARCHIVE_URL:-unused}"
export BACKUP_URL="${BACKUP_URL:-unused}"

PING_CLOUD_BASE_COMMIT_SHA=$(git rev-parse HEAD)
CURRENT_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if test "${CURRENT_GIT_BRANCH}" = 'HEAD'; then
  CURRENT_GIT_BRANCH=$(git describe --tags --always)
fi
export CLUSTER_STATE_REPO_URL=${CLUSTER_STATE_REPO_URL:-https://github.com/pingidentity/ping-cloud-base}

export K8S_GIT_URL="${K8S_GIT_URL:-https://github.com/pingidentity/ping-cloud-base}"
export K8S_GIT_BRANCH="${K8S_GIT_BRANCH:-${CURRENT_GIT_BRANCH}}"

export SSH_ID_PUB_FILE="${SSH_ID_PUB_FILE}"
export SSH_ID_KEY_FILE="${SSH_ID_KEY_FILE}"

export TARGET_DIR="${TARGET_DIR:-/tmp/sandbox}"

### Default environment variables ###
export REGISTRY_NAME='pingcloud-virtual.jfrog.io'
export PING_CLOUD_NAMESPACE='ping-cloud'

# Print out the values being used for each variable.
echo "Using TENANT_NAME: ${TENANT_NAME}"
echo "Using SIZE: ${SIZE}"

echo "Using IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
echo "Using CLUSTER_BUCKET_NAME: ${CLUSTER_BUCKET_NAME}"
echo "Using EVENT_QUEUE_NAME: ${EVENT_QUEUE_NAME}"
echo "Using REGION: ${REGION}"
echo "Using REGION_NICK_NAME: ${REGION_NICK_NAME}"
echo "Using PRIMARY_REGION: ${PRIMARY_REGION}"
echo "Using TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Using GLOBAL_TENANT_DOMAIN: ${GLOBAL_TENANT_DOMAIN}"
echo "Using PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"
echo "Using SECONDARY_TENANT_DOMAINS: ${SECONDARY_TENANT_DOMAINS}"

echo "Using CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"
echo "Using CLUSTER_STATE_REPO_PATH: ${REGION_NICK_NAME}"

echo "Using ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Using PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"

echo "Using K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Using K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

AUTO_GENERATED_STR='<auto-generated>'
echo "Using SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE:-${AUTO_GENERATED_STR}}"
echo "Using SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE:-${AUTO_GENERATED_STR}}"

echo "Using TARGET_DIR: ${TARGET_DIR}"
echo "Using IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY:-unused}

export PING_IDENTITY_DEVOPS_USER_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_USER}")
export PING_IDENTITY_DEVOPS_KEY_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_KEY}")
export NEW_RELIC_LICENSE_KEY_BASE64=$(base64_no_newlines "${NEW_RELIC_LICENSE_KEY}")

TEMPLATES_HOME="${SCRIPT_HOME}/templates"
BASE_DIR="${TEMPLATES_HOME}/base"
BASE_TOOLS_REL_DIR="base/cluster-tools"
BASE_PING_CLOUD_REL_DIR="base/ping-cloud"
REGION_DIR="${TEMPLATES_HOME}/region"

# Generate an SSH key pair for the CD tool.
if test -z "${SSH_ID_PUB_FILE}" && test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Generating key-pair for SSH access'
  generate_ssh_key_pair
elif test -z "${SSH_ID_PUB_FILE}" || test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Provide SSH key-pair files via SSH_ID_PUB_FILE/SSH_ID_KEY_FILE env vars, or omit both for key-pair to be generated'
  exit 1
else
  echo 'Using provided key-pair for SSH access'
  export SSH_ID_PUB=$(cat "${SSH_ID_PUB_FILE}")
  export SSH_ID_KEY_BASE64=$(base64_no_newlines "${SSH_ID_KEY_FILE}")
fi

# Get the known hosts contents for the cluster state repo host to pass it into the CD container.
parse_url "${CLUSTER_STATE_REPO_URL}"
echo "Obtaining known_hosts contents for cluster state repo host: ${URL_HOST}"

export KNOWN_HOSTS_CLUSTER_STATE_REPO="${KNOWN_HOSTS_CLUSTER_STATE_REPO:-$(ssh-keyscan -H "${URL_HOST}" 2>/dev/null)}"

# Delete existing target directory and re-create it
rm -rf "${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"

# Next build up the directory structure of the cluster-state repo
BOOTSTRAP_SHORT_DIR='fluxcd'
BOOTSTRAP_DIR="${TARGET_DIR}/${BOOTSTRAP_SHORT_DIR}"
CLUSTER_STATE_DIR="${TARGET_DIR}/cluster-state"
K8S_CONFIGS_DIR="${CLUSTER_STATE_DIR}/k8s-configs"

mkdir -p "${BOOTSTRAP_DIR}"
mkdir -p "${K8S_CONFIGS_DIR}"

cp ./update-cluster-state-wrapper.sh "${CLUSTER_STATE_DIR}"
cp ../.gitignore "${CLUSTER_STATE_DIR}"
cp ../k8s-configs/cluster-tools/base/git-ops/git-ops-command.sh "${K8S_CONFIGS_DIR}"
find "${TEMPLATES_HOME}" -type f -maxdepth 1 | xargs -I {} cp {} "${K8S_CONFIGS_DIR}"

cp -pr ../profiles/aws/. "${CLUSTER_STATE_DIR}"/profiles
echo "${PING_CLOUD_BASE_COMMIT_SHA}" > "${TARGET_DIR}/pcb-commit-sha.txt"

# Now generate the yaml files for each environment
ALL_ENVIRONMENTS='dev test stage prod'
ENVIRONMENTS="${ENVIRONMENTS:-${ALL_ENVIRONMENTS}}"

export CLUSTER_STATE_REPO_URL="${CLUSTER_STATE_REPO_URL}"

# The ENVIRONMENTS variable can either be the CDE names (e.g. dev, test, stage, prod) or the branch names (e.g.
# v1.8.0-dev, v1.8.0-test, v1.8.0-stage, v1.8.0-master). We must handle both cases. Note that the 'prod' environment
# will have a branch name suffix of 'master'.
for ENV_OR_BRANCH in ${ENVIRONMENTS}; do
# Run in a sub-shell so the current shell is not polluted with environment variables.
(
  test "${ENV_OR_BRANCH}" = 'prod' &&
      GIT_BRANCH='master' ||
      GIT_BRANCH="${ENV_OR_BRANCH}"

  ENV_OR_BRANCH_SUFFIX="${ENV_OR_BRANCH##*-}"
  test "${ENV_OR_BRANCH_SUFFIX}" = 'master' &&
      ENV='prod' ||
      ENV="${ENV_OR_BRANCH_SUFFIX}"

  # Export all the environment variables required for envsubst
  export ENV="${ENV}"
  export ENVIRONMENT_TYPE="${ENV}"

  # Set the cluster state repo branch to the default CDE branch, i.e. dev, test, stage or master.
  export CLUSTER_STATE_REPO_BRANCH="${GIT_BRANCH##*-}"

  # The base URL for kustomization files and environment will be different for each CDE.
  # On migrated customers, we must preserve the size of the customers.
  case "${ENV}" in
    dev | test)
      export KUSTOMIZE_BASE="${KUSTOMIZE_BASE:-test}"
      ;;
    stage | prod)
      export KUSTOMIZE_BASE="${KUSTOMIZE_BASE:-prod/${SIZE}}"
      ;;
  esac

  # Update the Let's encrypt server to use staging/production based on environment type.
  case "${ENV}" in
    dev | test | stage)
      export LETS_ENCRYPT_SERVER="${LETS_ENCRYPT_SERVER:-https://acme-staging-v02.api.letsencrypt.org/directory}"
      ;;
    prod)
      export LETS_ENCRYPT_SERVER="${LETS_ENCRYPT_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
      ;;
  esac

  # Set PF variables based on ENV
  case "${ENV}" in
    dev | test | stage)
      export PF_PD_BIND_PORT=1389
      export PF_PD_BIND_PROTOCOL=ldap
      export PF_PD_BIND_USESSL=false
      ;;
    prod)
      export PF_PD_BIND_PORT=5678
      export PF_PD_BIND_PROTOCOL=ldaps
      export PF_PD_BIND_USESSL=true
      ;;
  esac

  # Update the PF JVM limits based on environment.
  case "${ENV}" in
    dev | test)
      export PF_MIN_HEAP=256m
      export PF_MAX_HEAP=512m
      export PF_MIN_YGEN=128m
      export PF_MAX_YGEN=256m
      ;;
    stage | prod)
      export PF_MIN_HEAP=3072m
      export PF_MAX_HEAP=3072m
      export PF_MIN_YGEN=1536m
      export PF_MAX_YGEN=1536m
      ;;
  esac

  # Set PA variables
  case "${ENV}" in
    dev | test)
      export PA_WAS_MIN_HEAP=1024m
      export PA_WAS_MAX_HEAP=1024m
      export PA_WAS_MIN_YGEN=512m
      export PA_WAS_MAX_YGEN=512m
      ;;
    stage | prod)
      export PA_WAS_MIN_HEAP=2048m
      export PA_WAS_MAX_HEAP=2048m
      export PA_WAS_MIN_YGEN=1024m
      export PA_WAS_MAX_YGEN=1024m
      ;;
  esac
  export PA_WAS_GCOPTION='-XX:+UseParallelGC'

  export PA_MIN_HEAP=512m
  export PA_MAX_HEAP=512m
  export PA_MIN_YGEN=256m
  export PA_MAX_YGEN=256m
  export PA_GCOPTION='-XX:+UseParallelGC'

  # Zone for this region and the primary region
  if "${IS_BELUGA_ENV}"; then
    export DNS_ZONE="\${TENANT_DOMAIN}"
    export PRIMARY_DNS_ZONE="\${PRIMARY_TENANT_DOMAIN}"
  else
    export DNS_ZONE="\${ENV}-\${TENANT_DOMAIN}"
    export PRIMARY_DNS_ZONE="\${ENV}-\${PRIMARY_TENANT_DOMAIN}"
  fi

  "${IS_BELUGA_ENV}" &&
      export CLUSTER_NAME="${TENANT_NAME}" ||
      export CLUSTER_NAME="${ENV}"

  CLUSTER_NAME_LC="$(echo "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
  export CLUSTER_NAME_LC="${CLUSTER_NAME_LC}"

  add_derived_variables
  add_irsa_variables "${ACCOUNT_ID_PATH_PREFIX:-unused}" "${ENV}"
  add_nlb_variables "${NLB_EIP_PATH_PREFIX:-unused}" "${ENV}"

  echo ---
  echo "For environment ${ENV}, using variable values:"
  echo "CLUSTER_STATE_REPO_BRANCH: ${CLUSTER_STATE_REPO_BRANCH}"
  echo "ENVIRONMENT_TYPE: ${ENVIRONMENT_TYPE}"
  echo "KUSTOMIZE_BASE: ${KUSTOMIZE_BASE}"
  echo "LETS_ENCRYPT_SERVER: ${LETS_ENCRYPT_SERVER}"
  echo "CLUSTER_NAME: ${CLUSTER_NAME}"
  echo "PING_CLOUD_NAMESPACE: ${PING_CLOUD_NAMESPACE}"
  echo "DNS_ZONE: ${DNS_ZONE}"
  echo "PRIMARY_DNS_ZONE: ${PRIMARY_DNS_ZONE}"
  echo "LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
  echo "BACKUP_URL: ${BACKUP_URL}"

  # Build the kustomization file for the bootstrap tools for each environment
  echo "Generating bootstrap yaml"

  # The code for an environment is generated under a directory of the same name as what's provided in ENVIRONMENTS.
  ENV_BOOTSTRAP_DIR="${BOOTSTRAP_DIR}/${ENV_OR_BRANCH}"
  mkdir -p "${ENV_BOOTSTRAP_DIR}"

  cp "${TEMPLATES_HOME}/${BOOTSTRAP_SHORT_DIR}"/* "${ENV_BOOTSTRAP_DIR}"

  # Create a list of variables to substitute for the bootstrap tools
  substitute_vars "${ENV_BOOTSTRAP_DIR}" "${BOOTSTRAP_VARS}"

  # Copy the shared cluster tools and Ping yaml templates into their target directories
  echo "Generating tools and ping yaml"

  ENV_DIR="${K8S_CONFIGS_DIR}/${ENV_OR_BRANCH}"
  mkdir -p "${ENV_DIR}"

  cp -r "${BASE_DIR}" "${ENV_DIR}"
  cp -r "${REGION_DIR}/." "${ENV_DIR}/${REGION_NICK_NAME}"

  substitute_vars "${ENV_DIR}" "${REPO_VARS}" secrets.yaml env_vars

  # Regional enablement - add admins, backups, etc. to primary.
  if test "${TENANT_DOMAIN}" = "${PRIMARY_TENANT_DOMAIN}"; then
    PRIMARY_PING_KUST_FILE="${ENV_DIR}/${REGION_NICK_NAME}/kustomization.yaml"
    sed -i.bak 's/^\(.*remove-from-secondary-patch.yaml\)$/# \1/' "${PRIMARY_PING_KUST_FILE}"
    rm -f "${PRIMARY_PING_KUST_FILE}.bak"
  fi

  if "${IS_BELUGA_ENV}"; then
    BASE_ENV_VARS="${ENV_DIR}/base/env_vars"
    echo >> "${BASE_ENV_VARS}"
    echo "IS_BELUGA_ENV=true" >> "${BASE_ENV_VARS}"
  fi
)
done

cp -p push-cluster-state.sh "${TARGET_DIR}"

# Go back to previous working directory, if different
popd >/dev/null 2>&1

if ! "${QUIET}"; then
  echo
  echo '------------------------'
  echo '|  Next steps to take  |'
  echo '------------------------'
  echo "1) Run ${TARGET_DIR}/push-cluster-state.sh to push the generated code into the tenant cluster-state repo:"
  echo "${CLUSTER_STATE_REPO_URL}"
  echo
  echo "2) Add the following identity as the deploy key on the cluster-state (rw), if not already added:"
  echo "${SSH_ID_PUB}"
  echo
  echo "3) Deploy bootstrap files onto each CDE by navigating to ${BOOTSTRAP_DIR} and running:"
  echo 'kustomize build | kubectl apply -f -'
fi
