#!/usr/bin/env bash

# Expects
# brew install kubernetes-cli kubernetes-helm go skaffold jq httpie

# Based on GlooE Custom Auth server example
# https://gloo.solo.io/enterprise/authentication/custom_auth/

# Will exit script if we would use an uninitialised variable:
set -o nounset
# Will exit script when a simple command (not a control structure) fails:
set -o errexit

function print_error {
  read line file <<<$(caller)
  echo "An error occurred in line $line of file $file:" >&2
  sed "${line}q;d" "$file" >&2
}
trap print_error ERR

K8S_TOOL="${K8S_TOOL:-kind}" # kind or minikube

case "$K8S_TOOL" in
  kind)
    GO111MODULE="on" go get sigs.k8s.io/kind@v0.4.0

    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-kind}"

    # Delete existing cluster, i.e. restart cluster
    if [[ "$(kind get clusters)" == *"$DEMO_CLUSTER_NAME"* ]]; then
      kind delete cluster --name "$DEMO_CLUSTER_NAME"
    fi

    # Setup local Kubernetes cluster using kind (Kubernetes IN Docker) with control plane and worker nodes
    kind create cluster --name "${DEMO_CLUSTER_NAME}" --wait 60s

    # Configure environment for kubectl to connect to kind cluster
    export KUBECONFIG="$(kind get kubeconfig-path --name=${DEMO_CLUSTER_NAME})"
    ;;

  minikube)
    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-minikube}"

    minikube delete --profile "${DEMO_CLUSTER_NAME}" && true # Ignore errors
    minikube start --profile "${DEMO_CLUSTER_NAME}"

    source <(minikube docker-env -p "${DEMO_CLUSTER_NAME}")
    ;;
esac

skaffold config set --kube-context $(kubectl config current-context) local-cluster true

TILLER_MODE="${TILLER_MODE:-local}" # local or cluster

case "$TILLER_MODE" in
  local)
    # Run Tiller locally (external) to Kubernetes cluster as it's faster
    TILLER_PID_FILE=/tmp/tiller.pid
    if [ -f "${TILLER_PID_FILE}" ]; then
      (cat "${TILLER_PID_FILE}" | xargs kill) && true # Ignore errors killing old Tiller process
      rm "${TILLER_PID_FILE}"
    fi
    TILLER_PORT=":44134"
    ((tiller --storage=secret --listen=${TILLER_PORT}) & echo $! > "${TILLER_PID_FILE}" &)
    export HELM_HOST=${TILLER_PORT}
    ;;

  cluster)
    unset HELM_HOST
    # Install Helm and Tiller
    kubectl --namespace kube-system create serviceaccount tiller

    kubectl create clusterrolebinding tiller-cluster-rule \
      --clusterrole=cluster-admin \
      --serviceaccount=kube-system:tiller

    helm init --service-account tiller

    # Wait for tiller to be fully running
    kubectl --namespace kube-system rollout status deployment/tiller-deploy --watch=true
    ;;
esac

if [ -f ~/scripts/secret/glooe_license_key.sh ]; then
  # export GLOOE_LICENSE_KEY=<valid key>
  source ~/scripts/secret/glooe_license_key.sh
fi
if [ -z "${GLOOE_LICENSE_KEY}" ]; then
  echo "Must set GLOOE_LICENSE_KEY with GlooE activation key"
fi

helm repo add glooe http://storage.googleapis.com/gloo-ee-helm
helm upgrade --install glooe glooe/gloo-ee \
  --namespace gloo-system \
  --version 0.16.2 \
  --set-string license_key=${GLOOE_LICENSE_KEY}

# Deploy echo-server app and wait for it to fully deploy
( cd echo_server; skaffold run )
kubectl --namespace default rollout status deployment/echo-server --watch=true

# Create default Virtual Service with route to petclinic application root
kubectl --namespace gloo-system apply --filename - <<EOF
apiVersion: gateway.solo.io/v1
kind: VirtualService
metadata:
  name: default
  namespace: gloo-system
spec:
  virtualHost:
    domains:
    - '*'
    name: gloo-system.default
    routes:
    - matcher:
        prefix: /
      routeAction:
        single:
          upstream:
            name: default-echo-server-8080
            namespace: gloo-system
EOF

# Wait for deployment to be deployed and running
kubectl --namespace gloo-system rollout status deployment/gateway-proxy --watch=true

# Wait for Virtual Service changes to get applied to proxy
until [[ "$(kubectl --namespace gloo-system get virtualservice default -o=jsonpath='{.status.state}')" = "1" ]]; do
  sleep 5
done

# Port-forward HTTP port vs use `glooctl proxy url` as port-forward is more resistent to IP changes and works with kind
( kubectl --namespace gloo-system port-forward deployment/gateway-proxy 8080:8080 >/dev/null )&

sleep 15

PROXY_URL="http://localhost:8080"

# curl --silent --show-error ${PROXY_URL}/api/pets | jq
http --json ${PROXY_URL}/api/pets

#
# Add custom auth-server
#

# Deploy auth-server service
( cd grpc_auth_server; skaffold run )

# Wait for deployment to be deployed and running
kubectl --namespace gloo-system rollout status deployment/auth-server --watch=true

# Patch Gloo Settings and default Virtual Service to reference custom auth service
kubectl --namespace gloo-system patch settings default \
  --type='merge' \
  --patch "$(cat<<EOF
spec:
  extensions:
    configs:
      extauth:
        extauthzServerRef:
          name: gloo-system-auth-server-8000
          namespace: gloo-system
        requestBody:
          maxRequestBytes: 10240
        requestTimeout: 1s
EOF
)"

# Update Virtual Service to both reference custom auth-server and
#   add request transformation between auth-server and upstream echo-server
kubectl --namespace gloo-system apply --filename - <<EOF
apiVersion: gateway.solo.io/v1
kind: VirtualService
metadata:
  name: default
  namespace: gloo-system
spec:
  virtualHost:
    domains:
    - '*'
    name: gloo-system.default
    routes:
    - matcher:
        prefix: /
      routeAction:
        single:
          upstream:
            name: default-echo-server-8080
            namespace: gloo-system
      routePlugins:
        transformations:
          requestTransformation:
            transformationTemplate:
              headers:
                x-xform-a:
                  text: '{{ header("x-auth-a") }}'
    virtualHostPlugins:
      extensions:
        configs:
          extauth:
            customAuth: {}
EOF

sleep 5
until [[ "$(kubectl --namespace gloo-system get virtualservice default -o=jsonpath='{.status.state}')" = "1" ]]; do
  sleep 5
done

sleep 10

printf "Should return 200\n"
# curl --verbose --silent --show-error --write-out "%{http_code}\n" ${PROXY_URL}/api/pets/1 | jq
http --json ${PROXY_URL}/api/pets/1

printf "Should return 403\n"
# curl --verbose --silent --show-error --write-out "%{http_code}\n" ${PROXY_URL}/api/pets/2 | jq
http --json ${PROXY_URL}/api/pets/2

#
# Add Envoy Rate Limiting
#

kubectl --namespace gloo-system get settings/default --output yaml | tee original_settings.yaml

# Edit Envoy Rate Server Settings
# glooctl edit settings --namespace gloo-system --name default ratelimit custom-server-config

# descriptors:
# - key: x-a-header
#   rateLimit:
#     requestsPerUnit: 1
#     unit: MINUTE

kubectl --namespace gloo-system patch settings default \
  --type='merge' \
  --patch "$(cat<<EOF
spec:
  extensions:
    configs:
      envoy-rate-limit:
        customConfig:
          descriptors:
          - key: x-a-header
            rateLimit:
              requestsPerUnit: 1
              unit: MINUTE
EOF
)"

# glooctl edit virtualservice --namespace gloo-system --name default ratelimit custom-envoy-config

# rate_limits:
# - actions:
#   - requestHeaders:
#       descriptorKey: x-a-header
#       headerName: x-auth-a

kubectl --namespace gloo-system patch virtualservice default \
  --type='merge' \
  --patch "$(cat<<EOF
spec:
  virtualHost:
    virtualHostPlugins:
      extensions:
        configs:
          envoy-rate-limit:
            rate_limits:
            - actions:
              - requestHeaders:
                  descriptorKey: x-a-header
                  headerName: x-auth-a
EOF
)"

sleep 15

# Succeed
printf "Should return 200\n"
# curl --verbose --silent --show-error --write-out "%{http_code}\n" --header "x-req-a:1" ${PROXY_URL}/api/pets/1 | jq
http --json ${PROXY_URL}/api/pets/1 x-req-a:1

# Rate limited
printf "Should return 429\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:1

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:2

#
# Rate Limit against requestTransformation header
#

# glooctl edit virtualservice --namespace gloo-system --name default ratelimit custom-envoy-config

# rate_limits:
# - actions:
#   - requestHeaders:
#       descriptorKey: x-a-header
#       headerName: x-xform-a

kubectl --namespace gloo-system patch virtualservice default \
  --type='json' \
  --patch "$(cat<<EOF
[
    {
        "op": "replace",
        "path": "/spec/virtualHost/virtualHostPlugins/extensions/configs/envoy-rate-limit/rate_limits/0/actions/0/requestHeaders/headerName",
        "value": "x-xform-a"
    }
]
EOF
)"

sleep 15

# Succeed
printf "Should return 200\n"
# curl --verbose --silent --show-error --write-out "%{http_code}\n" --header "x-req-a:1" ${PROXY_URL}/api/pets/1 | jq
http --json ${PROXY_URL}/api/pets/1 x-req-a:1

# Rate limited
printf "Should return 429\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:1

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:2

#
# Rate Limiting descriptor experiments
#

# Edit Envoy Rate Server Settings
# glooctl edit settings --namespace gloo-system --name default ratelimit custom-server-config

# descriptors:
# - key: x-a-header
#   rateLimit:
#     requestsPerUnit: 1
#     unit: MINUTE
# - key: x-b-header
#   rateLimit:
#     requestsPerUnit: 1
#     unit: MINUTE

kubectl --namespace gloo-system patch settings default \
  --type='merge' \
  --patch "$(cat<<EOF
spec:
  extensions:
    configs:
      envoy-rate-limit:
        customConfig:
          descriptors:
          - key: x-a-header
            rateLimit:
              requestsPerUnit: 1
              unit: MINUTE
          - key: x-b-header
            rateLimit:
              requestsPerUnit: 1
              unit: MINUTE
          - key: x-c-header
            rateLimit:
              requestsPerUnit: 2
              unit: MINUTE
EOF
)"

# add route specifc rate limiting
kubectl --namespace gloo-system apply --filename - <<EOF
apiVersion: gateway.solo.io/v1
kind: VirtualService
metadata:
  name: default
  namespace: gloo-system
spec:
  virtualHost:
    domains:
    - '*'
    name: gloo-system.default
    routes:
    - matcher:
        prefix: /other/2
      routeAction:
        single:
          upstream:
            name: default-echo-server-8080
            namespace: gloo-system
      routePlugins:
        extensions:
          configs:
            envoy-rate-limit:
              includeVhRateLimits: false
              rateLimits:
              - actions:
                - requestHeaders:
                    descriptorKey: x-b-header
                    headerName: x-auth-b
              - actions:
                - requestHeaders:
                    descriptorKey: x-c-header
                    headerName: x-auth-c
        transformations:
          requestTransformation:
            transformationTemplate:
              headers:
                x-xform-c:
                  text: '{{ header("x-auth-c") }}'
    - matcher:
        prefix: /other
      routeAction:
        single:
          upstream:
            name: default-echo-server-8080
            namespace: gloo-system
      routePlugins:
        extensions:
          configs:
            envoy-rate-limit:
              includeVhRateLimits: false
              rateLimits:
              - actions:
                - requestHeaders:
                    descriptorKey: x-b-header
                    headerName: x-auth-b
        transformations:
          requestTransformation:
            transformationTemplate:
              headers:
                x-xform-b:
                  text: '{{ header("x-auth-b") }}'
    - matcher:
        prefix: /
      routeAction:
        single:
          upstream:
            name: default-echo-server-8080
            namespace: gloo-system
      routePlugins:
        extensions:
          configs:
            envoy-rate-limit:
              includeVhRateLimits: true
              rateLimits:
              - actions:
                - requestHeaders:
                    descriptorKey: x-b-header
                    headerName: x-auth-b
        transformations:
          requestTransformation:
            transformationTemplate:
              headers:
                x-xform-a:
                  text: '{{ header("x-auth-a") }}'
    virtualHostPlugins:
      extensions:
        configs:
          envoy-rate-limit:
            rate_limits:
            - actions:
              - requestHeaders:
                  descriptorKey: x-a-header
                  headerName: x-auth-a
          extauth:
            customAuth: {}
EOF

sleep 15

# Succeed
printf "Should return 200\n"
# curl --verbose --silent --show-error --write-out "%{http_code}\n" --header "x-req-a:10" --header "x-req-b:10" --header "always-approve:true" ${PROXY_URL}/api/pets/1 | jq
http --json ${PROXY_URL}/api/pets/1 x-req-a:10 x-req-b:10 always-approve:true

# Rate limited
printf "Should return 429\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:10 x-req-b:10 always-approve:true

# Rate limited
printf "Should return 429\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:20 x-req-b:10 always-approve:true

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/api/pets/1 x-req-a:30 x-req-b:30 always-approve:true

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/other x-req-a:30 x-req-b:40 always-approve:true

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/other x-req-a:30 x-req-b:50 always-approve:true

# Rate limited
printf "Should return 429\n"
http --json ${PROXY_URL}/other x-req-a:40 x-req-b:50 always-approve:true

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/other/2 x-req-a:50 x-req-b:60 x-req-c:10 always-approve:true

# Succeed as `c` header is 2 per minute
printf "Should return 200\n"
http --json ${PROXY_URL}/other/2 x-req-a:50 x-req-b:61 x-req-c:10 always-approve:true

# Rate Limit
printf "Should return 429\n"
http --json ${PROXY_URL}/other/2 x-req-a:50 x-req-b:62 x-req-c:10 always-approve:true

# Succeed
printf "Should return 200\n"
http --json ${PROXY_URL}/other/2 x-req-a:50 x-req-b:63 x-req-c:11 always-approve:true
