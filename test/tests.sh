#!/usr/bin/env bash

set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
KIND_VERSION=v0.8.1
KUBE_VERSION=v1.17.11
KUBERNETES_CHAOS_HELM_VERSION=2.2.3

function setup() {
case $1 in
    kind)
    setup_kind "$@"
    ;;
    eks)
    setup_eks "$@"
    ;;
esac
}

function setup_kind() {

    if [[ ! $(command -v kind) ]]; then
        echo ">>> Installing Kind"
        curl -Lo ./kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
        chmod +x kind
        sudo mv kind /usr/local/bin/kind
    fi

    echo ">>> Creating kind cluster"
    kind create cluster --wait 5m --image kindest/node:${KUBE_VERSION} --config "${REPO_ROOT}/kind-setup/kind-config.yaml"
    kubectl cluster-info --context kind-kind
}

function setup_eks() {
    if [[ ! $(command -v eksctl) ]]; then
        echo ">>> Installing eksctl"
        curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
        sudo mv /tmp/eksctl /usr/local/bin
        eksctl version
    fi

    echo ">>> Creating EKS cluster"
    eksctl create cluster --name=chaos-demo --region=ap-northeast-1 \
        --node-type=r5.large --nodes=3 --nodes-min=1 --nodes-max=4 \
        --set-kubeconfig-context=false

    aws eks update-kubeconfig --name chaos-demo --alias chaos-demo
}

function cleanup() {
    case $1 in
    kind)
        echo ">>> Shutting down kind cluster"
        kind delete cluster
        ;;
    eks)
        echo ">>> Shutting down EKS cluster"
        eksctl delete cluster --name chaos-demo --region ap-northeast-1 --wait
        ;;
    esac
}

function install_dependencies() {

    echo ">>> Deploying sock shop"
    kubectl apply -f "${REPO_ROOT}/deploy/sock-shop.yaml"
    kubectl apply -f "${REPO_ROOT}/deploy/random-log-counter.yaml"

    echo ">>> Installing Litmus Operator"
    if [[ ! $(command -v helm) ]]; then
        echo ">>> Installing Helm"
        (
            cd /tmp
            curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz && sudo mv linux-amd64/helm /usr/local/bin/ && rm -rf linux-amd64
        )
    fi
    helm repo add litmus https://litmuschaos.github.io/litmus-helm/
    kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v1.9.0.yaml

    echo ">>> Installing Litmus Experiments for kubernetes generic chaos"
    helm upgrade -i kubernetes-chaos litmus/kubernetes-chaos --version=${KUBERNETES_CHAOS_HELM_VERSION} \
        --wait \
        --namespace sock-shop
    kubectl get chaosexperiments -n sock-shop

    echo ">>> Initialising chaos RBAC"
    kubectl apply -f "${REPO_ROOT}/deploy/litmus-rbac.yaml"
}

function run_experiment() {
    experiment=$1
    experiment_file="${REPO_ROOT}/litmus/${experiment}.yaml"
    if [[ ! -e "${experiment_file}" ]]; then
        echo "${experiment_file} not exists"
        exit 1
    fi

    result_name=$(yq r "${experiment_file}" 'metadata.name')
    namespace=$(yq r "${experiment_file}" 'metadata.namespace')

    echo ">> Waiting roll out all"
    kubectl -n "${namespace}" get deploy -o json | jq -r '.items[].metadata.name' | xargs -t -n 1 -P 2 kubectl -n "${namespace}" rollout status deploy

    echo ">> Deploying ${result_name}.${namespace}"
    set +e
    kubectl -n "${namespace}" delete chaosengine "${result_name}" 2> /dev/null
    set -e
    kubectl apply -f "${experiment_file}"

    attempts=50
    count=0
    ok=false
    echo ">>> Running chaos"
    until ${ok}; do
        kubectl -n "${namespace}" get chaosengine "${result_name}" -o jsonpath='{.status.experiments[0].status}' | grep "Completed" && ok=true || ok=false
        sleep 10
        set +e
        kubectl -n "${namespace}" logs --since=10s -l name="${experiment}"
        set -e
        count=$((count + 1))
        if [[ ${count} -eq ${attempts} ]]; then
            kubectl -n "${namespace}" describe chaosengine "${result_name}"
            kubectl -n "${namespace}" logs -l name="${experiment}"
            echo "No more retries left"
            exit 1
        fi
    done

    res=$(kubectl -n "${namespace}" get chaosresult "${result_name}-${experiment}" -o jsonpath='{.status.experimentstatus.verdict}')
    echo "Status: ${res}"
    if [ "${res}" != "Success" ]; then
        kubectl -n "${namespace}" describe chaosresult "${result_name}-${experiment}"
        kubectl -n "${namespace}" logs -l name="${experiment}"
        exit 1
    fi
}

function run() {
    run_experiment "$@"
}

function list() {
    kubectl -n sock-shop get chaosexperiments -o json | jq -r '.items[].metadata.name'
}

case "$1" in
    start)
        shift 1
        setup "$@"
        ;;
    stop)
        shift 1
        cleanup "$@"
        ;;
    install)
        shift 1
        install_dependencies "$@"
        ;;
    list)
        shift 1
        list "$@"
        ;;
    run)
        shift 1
        run "$@"
        ;;
esac
