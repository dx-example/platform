#!/bin/bash

# This script prepares all the configuration files and install components such as argocd

HELM_ARGOCD=argocd
HELM_PLATFORM=platform-name
PLATFORM_NS=platform
LETSENCRYPT_EMAIL=admin@dx-book.com

GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --github-token=*)
        export TOKEN="${key#*=}" # Extracts value after '='
        shift                    # Removes processed argument
        ;;
    --upgrade)
        UPGRADE=true
        shift # Removes processed argument
        ;;
    *) # Unknown option
        echo "Unknown argument: $key"
        exit 1
        ;;
    esac
done

# make sure the environment variables defined before are availble for this script
source ~/.profile

# make sure we have valid access to the cluster
kubectl cluster-info
# Capture the exit status
status=$?
if [ $status -ne 0 ]; then
    kops export kubeconfig --admin --state $KOPS_STATE_STORE --name=$CLUSTER_NAME
fi


# Function to check if all applications are healthy
all_apps_healthy() {
    # Fetch all applications and their statuses
    statuses=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.health.status}')

    # Check each status
    for status in $statuses; do
        if [[ $status != "Healthy" ]]; then
            return 1
        fi
    done
    return 0
}

function applyLetsEncryptClusterIssuer() {
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $LETSENCRYPT_EMAIL
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
    - http01:
        ingress:
          class: traefik
EOF
}

function encryptGitHubReposSecret() {
    file="templates/base/secrets/github-environments.yaml" 

    # if the file doesn't exist in the helm ignore files
    if ! grep -q "^$file$" chart/.helmignore; then
        helm template $HELM_PLATFORM chart \
            --show-only $file \
            --values chart/values.yaml 2>/dev/null \
            | kubeseal --controller-name=sealed-secrets \
                --controller-namespace=platform \
                --format yaml > chart/templates/base/secrets/github-environments-encrypted.yaml

        echo "Secret github-environments is now encrypted"
        # when the secret is generated, we add the original to the helm ignore
        # when we'll apply this chart, only the encrypted will be submited
        # the original secret will stay here, inside your personal codespace only
        echo "$file" >> chart/.helmignore
    fi
    # make sure the original secret won't go to git
    if git ls-files --error-unmatch $file > /dev/null 2>&1; then
        # Remove the file from Git while keeping it locally
        git rm --cached $chart/file

        # Append the file or pattern to .gitignore if not already present
        if ! grep -q "^chart/$file$" .gitignore; then
            echo "$file" >> .gitignore
        fi
    fi
}

function encryptGitHubAdminAuthSecret() {
    file="templates/base/secrets/github-admin-auth.yaml"
    # if the file doesn't exist in the helm ignore files
    if ! grep -q "^$file$" chart/.helmignore; then
        helm template $HELM_PLATFORM chart \
            --show-only $file \
            --values chart/values.yaml 2>/dev/null \
            | kubeseal --controller-name=sealed-secrets \
                --controller-namespace=platform \
                --format yaml > chart/templates/base/secrets/github-admin-auth-encrypted.yaml

        echo "Secret github-admin-auth is now encrypted"
        # when the secret is generated, we add the original to the helm ignore
        # when we'll apply this chart, only the encrypted will be submited
        # the original secret will stay here, inside your personal codespace only
        echo "$file" >> chart/.helmignore
    fi
    # make sure the original secret won't go to git
    if git ls-files --error-unmatch chart/$file > /dev/null 2>&1; then
        # Remove the file from Git while keeping it locally
        git rm --cached chart/$file

        # Append the file or pattern to .gitignore if not already present
        if ! grep -q "^chart/$file$" .gitignore; then
            echo "chart/$file" >> .gitignore
        fi
    fi
}

function encryptAWSEcrSecrets() {

    path="templates/secrets"
    file="aws-dev.yaml"
    dest="chart/templates/each/dependencies/$path/aws-dev-encrypted.yaml"

    # if the file doesn't exist in the helm ignore files
    # which is where we store if the secret was already encrypted or not
    if ! grep -q "^$file$" chart/.helmignore; then
        cd chart/templates/each/dependencies || return

        helm template dependencies . \
            --show-only $path/$file \
            --values values.yaml 2>/dev/null \
            | kubeseal --controller-name=sealed-secrets \
                --controller-namespace=platform \
                --scope=cluster-wide \
                --format yaml > $path/aws-dev-encrypted.yaml

        echo "Secret $file is now encrypted"
        # when the secret is generated, we add the original to the helm ignore
        # when we'll apply this chart, only the encrypted will be submited
        # the original secret will stay here, inside your personal codespace only
        cd ../../../../

        # kubeseal adds a --- separator and we need to clean it
        # we update the namespace to the namespace variable again
        sed -i '/^---$/d' $dest
        echo "$path/$file" >> chart/.helmignore
        yq eval '.metadata.namespace = "{{ .Values.repo }}-development"' $dest -i
        yq eval '.spec.template.metadata.namespace = "{{ .Values.repo }}-development"' $dest -i
        
    fi

    # make sure the original secret won't go to git
    fullpath=chart/templates/each/dependencies/$path/$file
    if git ls-files --error-unmatch $fullpath > /dev/null 2>&1; then
        # Remove the file from Git while keeping it locally
        git rm --cached $fullpath
        git commit -m "Removed $fullpath"
        # Append the file or pattern to .gitignore if not already present
        if ! grep -q "^$fullpath$" .gitignore; then
            echo "$fullpath" >> .gitignore
        fi
    fi
}

function cleanupSecretsFromValuesYaml() {
    yq eval -i '.aws.secret.AWS_ACCESS_KEY_ID = null | .aws.secret.AWS_SECRET_ACCESS_KEY = null' chart/values.yaml
    yq eval -i '.github.secrets.admin = null | .github.secrets.repositories = null' chart/values.yaml
    cp -f chart/values.yaml chart/templates/gene/values.yaml
    cp -f chart/values.yaml chart/templates/each/dependencies/values.yaml
}

# validations
if [ -z "$GITHUB_TOKEN" ]; then
    echo "You should run this command inside a GitHub Codespace"
fi

if [ -z "$AWS_ACCOUNT" ] || [ -z "$CLUSTER_NAME" ]; then
    echo "Missing environment variables such as AWS_ACCOUNT or CLUSTER_NAME"
fi

if [[ -z "$TOKEN" ]]; then
    echo "GitHub Token not provided"
    exit 1
fi

# replace the already known values.yaml file using the environment variables
yq eval -i '.org = env(GITHUB_ORG) | .domain = env(CLUSTER_NAME) | .root = env(CLUSTER_DOMAIN)' chart/values.yaml
yq eval -i '.aws.account = env(AWS_ACCOUNT) | .aws.account style="double" | .aws.region = env(AWS_DEFAULT_REGION)' chart/values.yaml
yq eval -i '.aws.secret.AWS_ACCESS_KEY_ID = env(AWS_ACCESS_KEY_ID) | .aws.secret.AWS_SECRET_ACCESS_KEY = env(AWS_SECRET_ACCESS_KEY)' chart/values.yaml
cp -f chart/values.yaml chart/templates/gene/values.yaml
cp -f chart/values.yaml chart/templates/each/dependencies/values.yaml

# some of the variables we do not know yet, such as the github admin secret and the service repositories secret
# so let's replace it here
# trying to use the logged in token from the codespace
yq eval -i '.github.secrets.repositories = env(TOKEN)' chart/values.yaml

# install argocd
if helm list --all-namespaces | grep -q "^$HELM_ARGOCD\s"; then
    echo -n ""
else
    helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null
    helm repo update &>/dev/null
    kubectl create namespace argocd &>/dev/null
    helm install argocd argo/argo-cd --namespace argocd --set configs.params."server\.insecure"=true &>/dev/null
fi

sleep 5

# attempt to login to argocd
if argocd version --client=false --port-forward --port-forward-namespace argocd &>/dev/null; then
    echo -e "${GREEN}You are logged into ArgoCD.${NC}"
else
    argocd login localhost:8080 --username admin \
        --port-forward --port-forward-namespace argocd --plaintext \
        --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
fi

# verify if the chart is installed already, if not, then install
STATUS=$(helm status "$HELM_PLATFORM" 2>&1)
if [[ "$STATUS" == "Error: release: not found" ]]; then
    helm upgrade $HELM_PLATFORM chart --create-namespace --install
    sleep 5
fi

if [[ $UPGRADE == true ]]; then
    helm upgrade $HELM_PLATFORM chart --create-namespace --install
fi

# wait for traefik load balancer to be available
# then update the Route53 DNS with traefik load balancer endpoint
END_TIME=$(($(date +%s) + 120))
while true; do
    STATUS=$(helm status "$HELM_PLATFORM" --output=json | jq -r .info.status)
    if [[ "$STATUS" == "deployed" ]]; then
        echo "Helm release $HELM_PLATFORM has been successfully deployed!"

        echo "Waiting for traefik deployment to be ready and to have an available replica..."
        while true; do
            # Get desired and available replicas
            AVAILABLE_REPLICAS=$(kubectl get deployment "traefik" -n "$PLATFORM_NS" -o=jsonpath='{.status.availableReplicas}')
            if [[ "1" == "$AVAILABLE_REPLICAS" ]]; then

                echo -e "${GREEN}Traefik is healthy!${NC}"

                ### The traefik deployment is healthy
                ### Now we wait until it creates a load balancer and have a hostname available
                while true; do
                    LB_HOSTNAME=$(kubectl get svc traefik -n platform -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
                    if [ -n "$LB_HOSTNAME" ]; then
                        echo "Traefik is healthy and has a LoadBalancer attached!"
                        break
                    else
                        echo -e "Waiting for traefik to have an available cluster load balancer..."
                        sleep 15  # wait for 10 seconds before rechecking
                    fi
                done

                ### Get the zone id from route 53
                HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq --arg domain "$CLUSTER_DOMAIN." '.HostedZones[] | select(.Name==$domain) | .Id | split("/")[2]' | tr -d '"')

                echo "Updating the Route53 DNS records to point to $LB_HOSTNAME (Traefik Load Balancer)"
                # Check if the record already exists
                RECORD_EXISTS_1=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID | jq -r ".ResourceRecordSets[] | select(.Name == \"$CLUSTER_NAME.\")")

                # verify if the route 53 dns upadte is needed
                if [ "$LB_HOSTNAME" != "$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords[0].Value" | tr -d '"')" ]; then
                    echo "Updating DNS records in Route53"

                    if [[ ! -z $RECORD_EXISTS_1 ]]; then
                        # Delete the record
                        echo -e "Route53 DNS record already exists, deleting first..."
                        aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
                          \"Comment\": \"Delete record\",
                          \"Changes\": [{
                          \"Action\": \"DELETE\",
                          \"ResourceRecordSet\": {
                              \"Name\": \"${CLUSTER_NAME}\",
                              \"Type\": \"CNAME\",
                              \"TTL\": 1,
                              \"ResourceRecords\": $(echo "${RECORD_EXISTS_1}" | jq -c ".ResourceRecords")
                          }
                          }]
                      }" >/dev/null 2>&1

                        echo -e "Also deleting the *.domain"

                        # Delete the record for the *.domain
                        aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
                          \"Comment\": \"Delete record\",
                          \"Changes\": [{
                          \"Action\": \"DELETE\",
                          \"ResourceRecordSet\": {
                              \"Name\": \"*.${CLUSTER_NAME}\",
                              \"Type\": \"CNAME\",
                              \"TTL\": 1,
                              \"ResourceRecords\": $(echo "${RECORD_EXISTS_1}" | jq -c ".ResourceRecords")
                          }
                          }]
                      }" >/dev/null 2>&1
                    fi

                    # Create the record again
                    aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
                      \"Comment\": \"Create record\",
                      \"Changes\": [{
                          \"Action\": \"CREATE\",
                          \"ResourceRecordSet\": {
                          \"Name\": \"${CLUSTER_NAME}\",
                          \"Type\": \"CNAME\",
                          \"TTL\": 1,
                          \"ResourceRecords\": [{
                              \"Value\": \"${LB_HOSTNAME}\"
                          }]
                          }
                      }]
                    }" >/dev/null 2>&1

                    echo "Creating DNS records 2"
                    # Create the record again for the *.domain
                    aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
                        \"Comment\": \"Create record\",
                        \"Changes\": [{
                            \"Action\": \"CREATE\",
                            \"ResourceRecordSet\": {
                            \"Name\": \"*.${CLUSTER_NAME}\",
                            \"Type\": \"CNAME\",
                            \"TTL\": 1,
                            \"ResourceRecords\": [{
                                \"Value\": \"${LB_HOSTNAME}\"
                            }]
                            }
                        }]
                    }" >/dev/null 2>&1
                else
                    echo "Skipping Route53 Hostname update since it's already in sync"
                fi

                # apply the cluster issuer to generate dynamic ssl certificates
                applyLetsEncryptClusterIssuer

                echo -e "\n${GREEN}Domain https://argocd.$CLUSTER_NAME should now be available (TTL 60)${NC}"
                echo -e "${GREEN}ArgoCD admin password is: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"

                sleep 2

                # Wait loop
                # echo -e "\nVerifying ArgoCD applications status.."
                # while ! all_apps_healthy; do
                #     echo "Waiting for all ArgoCD applications to be healthy..."
                #     sleep 10 # Wait for 10 seconds before rechecking
                # done
                # echo "All ArgoCD applications are healthy!"

                # verify if generators is already deployed or not
                kubectl get applications/generators -n argocd &>/dev/null
                # $? is a special variable that holds the exit status of the last command executed
                if [[ $? -ne 0 ]]; then
                    echo "Activating the generators..."
                    # helm upgrade $HELM_PLATFORM chart --set generators=true
                else
                    echo "Generators are active"
                fi

                #### from here we assume the platform tools are already deployed and healthy and the generators as well
                #### almost ready to commit the platform to git to reflect in the cluster
                #### just need to encrypt the secrets

                encryptGitHubReposSecret
                encryptGitHubAdminAuthSecret
                encryptAWSEcrSecrets


                ### here we remove the secrets from the values.yaml we used before
                ### now they are encrypted and can safely be added to the github repository
                cleanupSecretsFromValuesYaml
                
                exit 0

            else
                sleep 2
            fi
        done

    elif [[ "$(date +%s)" -gt "$END_TIME" ]]; then
        echo "Timed out waiting for Helm release $HELM_PLATFORM to be deployed."
        helm upgrade $HELM_PLATFORM chart --create-namespace --install
    else
        sleep 7
    fi
done
