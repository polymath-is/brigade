#!/bin/bash
# custom script for e2e testing
# ${BIN_DIR} must exist and be part of $PATH

# kudos to https://elder.dev/posts/safer-bash/
set -o errexit # script exits when a command fails == set -e
set -o nounset # script exits when tries to use undeclared variables == set -u
#set -o xtrace # trace what's executed == set -x (useful for debugging)
set -o pipefail # causes pipelines to retain / set the last non-zero status

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
BIN_DIR="${BIN_DIR:-"$(mktemp -d)"}"

# This script may be run in the form of a Brigade KindJob,
# wherein the kind cluster will have already been pre-provisioned,
# hence the need to be able to opt-out
CREATE_KIND="${CREATE_KIND:-true}"

CLIENT_PLATFORM="${CLIENT_PLATFORM:-linux}"
CLIENT_ARCH="${CLIENT_ARCH:-amd64}"

KUBECTL_PLATFORM=${CLIENT_PLATFORM}/${CLIENT_ARCH}
KUBECTL_VERSION=v1.17.2
KUBECTL_EXECUTABLE=kubectl

KIND_PLATFORM=kind-${CLIENT_PLATFORM}-${CLIENT_ARCH}
KIND_VERSION=v0.7.0
KIND_EXECUTABLE=kind

HELM_PLATFORM=${CLIENT_PLATFORM}-${CLIENT_ARCH}
HELM_VERSION=helm-v3.0.3
HELM_EXECUTABLE=helm3

########################################################################################################################################################

function prerequisites_check(){
    if ! [ -x "$(command -v ${KUBECTL_EXECUTABLE})" ]; then
      echo "Installing kubectl version ${KUBECTL_VERSION}..."
      curl -o ${BIN_DIR}/${KUBECTL_EXECUTABLE} -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/${KUBECTL_PLATFORM}/kubectl && \
        chmod +x ${BIN_DIR}/${KUBECTL_EXECUTABLE}
    fi

    if ! [ -x "$(command -v ${KIND_EXECUTABLE})" ]; then
      echo "Installing kind version ${KIND_VERSION}..."
      wget -O ${BIN_DIR}/${KIND_EXECUTABLE} https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/${KIND_PLATFORM} && \
        chmod +x ${BIN_DIR}/${KIND_EXECUTABLE}
    fi

    if ! [ -x "$(command -v ${HELM_EXECUTABLE})" ]; then
      echo "Installing helm version ${HELM_VERSION}..."
      wget -O ${BIN_DIR}/${HELM_VERSION}-${HELM_PLATFORM}.tar.gz https://get.helm.sh/${HELM_VERSION}-${HELM_PLATFORM}.tar.gz && \
        tar -xvzf ${BIN_DIR}/${HELM_VERSION}-${HELM_PLATFORM}.tar.gz -C ${BIN_DIR} && \
        rm -rf ${BIN_DIR}/${HELM_VERSION}-${HELM_PLATFORM}.tar.gz && \
        chmod +x ${BIN_DIR}/${HELM_PLATFORM}/helm && \
        mv ${BIN_DIR}/${HELM_PLATFORM}/helm ${BIN_DIR}/$HELM_EXECUTABLE
    fi

    export PATH="${BIN_DIR}:${PATH}"
}


function install_helm_project(){
    # init helm
    $HELM_EXECUTABLE init

    # add brigade chart repo
    $HELM_EXECUTABLE repo add brigade https://brigadecore.github.io/charts

    # install the images onto kind cluster
    HELM=$HELM_EXECUTABLE make helm-install
}

function wait_for_deployments() {
    echo "-----Waiting for Brigade components' deployments-----"
    # https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-brigade-api
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-brigade-cr-gw
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-brigade-ctrl
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-brigade-generic-gateway
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-brigade-github-app
    "${DIR}"/wait-for-deployment.sh -n default brigade-server-kashti
}

function create_verify_test_project(){
    echo "-----Creating a test project-----"
    go run "${DIR}"/../brig/cmd/brig/main.go project create -f "${DIR}"/testproject.yaml -x

    echo "-----Checking if the test project secret was created-----"
    PROJECT_NAME=$($KUBECTL_EXECUTABLE get secret -l app=brigade,component=project,heritage=brigade -o=jsonpath='{.items[0].metadata.name}')
    if [ $PROJECT_NAME != "$TEST_PROJECT_NAME" ]; then
        echo "Wrong secret name. Expected $TEST_PROJECT_NAME, got $PROJECT_NAME"
        exit 1
    fi
}

function run_verify_build(){
    echo "-----Running a Build on the test project-----"
    go run "${DIR}"/../brig/cmd/brig/main.go run e2eproject -f "${DIR}"/test.js

    # get the worker pod name
    WORKER_POD_NAME=$($KUBECTL_EXECUTABLE get pod -l component=build,heritage=brigade,project=$TEST_PROJECT_NAME -o=jsonpath='{.items[0].metadata.name}')

    # get the number of lines the expected log output appears
    LOG_LINES=$($KUBECTL_EXECUTABLE logs $WORKER_POD_NAME | grep "==> handling an 'exec' event" | wc -l)

    if [ $LOG_LINES != 1 ]; then
        echo "Did not find expected output on worker Pod logs"
        exit 1
    fi
}

########################################################################################################################################################

prerequisites_check

# create kind k8s cluster
if [[ "${CREATE_KIND}" == "true" ]]; then
  ${KIND_EXECUTABLE} create cluster --image kindest/node:${KUBECTL_VERSION}
fi

function finish {
  if [[ "${CREATE_KIND}" == "true" ]]; then
    echo "-----Cleaning up-----"
    ${KIND_EXECUTABLE} delete cluster
  fi
}

trap finish EXIT

# build all images and load them onto kind
DOCKER_ORG=brigadecore make build-all-images load-all-images

install_helm_project # installs helm and Brigade onto kind

TEST_PROJECT_NAME=brigade-5b55ed522537b663e178f751959d234fd650d626f33f70557b2e82

wait_for_deployments # waits for Brigade deployments
create_verify_test_project # create a test project
run_verify_build # run a custom build and make sure it's completed

