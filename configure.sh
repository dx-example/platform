#!/bin/bash

HELM_ARGOCD=argocd
HELM_PLATFORM=platform-name
ARGOCD_ADMIN=qwe741iop
PLATFORM_NS=platform
LETSENCRYPT_EMAIL=admin@dx-book.com

yq eval -i '.org = env(GITHUB_ORG) | .domain = env(CLUSTER_NAME) | .root = env(CLUSTER_DOMAIN)' chart/values.yaml
yq eval -i '.aws.account = env(AWS_ACCOUNT) | .aws.region = env(AWS_DEFAULT_REGION)' chart/values.yaml

if helm list --all-namespaces | grep -q "^$HELM_ARGOCD\s"; then
  echo -n ""
else
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  kubectl create namespace argocd
  helm install argocd argo/argo-cd --namespace argocd --set configs.params."server\.insecure"=true
fi

sleep 1

# # Attempt to fetch version information
# if argocd version --client=false &> /dev/null; then
#     echo "You are logged into ArgoCD."
# else
#     echo "Logging in ArgoCD"
#     argocd login localhost:8080 --username admin \
#     --port-forward --port-forward-namespace argocd --plaintext \
#     --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
#     argocd account update-password \
#         --port-forward --port-forward-namespace argocd --plaintext \
#         --current-password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) \
#         --new-password $ARGOCD_ADMIN
# fi

END_TIME=$(($(date +%s) + 60))
while true; do
    STATUS=$(helm status "$HELM_PLATFORM" --output=json | jq -r .info.status)
    if [[ "$STATUS" == "deployed" ]]; then
        echo "Helm release $HELM_PLATFORM has been successfully deployed!"

        echo "Waiting until the traefik load balancer is available"
        while true; do
            # Get desired and available replicas
            AVAILABLE_REPLICAS=$(kubectl get deployment "traefik" -n "$PLATFORM_NS" -o=jsonpath='{.status.availableReplicas}')
            if [[ "1" == "$AVAILABLE_REPLICAS" ]]; then
                echo "Traefik is healthy!"
                
                HOSTNAME=$(kubectl get svc traefik -n platform -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
                HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq --arg domain "$CLUSTER_DOMAIN." '.HostedZones[] | select(.Name==$domain) | .Id | split("/")[2]' | tr -d '"')

                echo "Updating the Route53 DNS records to point to $HOSTNAME (Traefik Load Balancer)"
                # Check if the record already exists
                RECORD_EXISTS_1=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID | jq -r ".ResourceRecordSets[] | select(.Name == \"$CLUSTER_NAME.\")")

                # verify if the route 53 dns upadte is needed
                if [ "$HOSTNAME" != "$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords[0].Value" | tr -d '"')" ]; then
                  echo "Updating DNS records in Route53"

                  if [[ ! -z $RECORD_EXISTS_1 ]]; then
                      # Delete the record
                      aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch '{
                          "Comment": "Delete record",
                          "Changes": [{
                          "Action": "DELETE",
                          "ResourceRecordSet": {
                              "Name": "'$CLUSTER_NAME'",
                              "Type": "CNAME",
                              "TTL": 60,
                              "ResourceRecords": '$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords")'
                          }
                          }]
                      }' > /dev/null 2>&1
                      
                      # Delete the record for the *.domain
                      aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch '{
                          "Comment": "Delete record",
                          "Changes": [{
                          "Action": "DELETE",
                          "ResourceRecordSet": {
                              "Name": "'*.$CLUSTER_NAME'",
                              "Type": "CNAME",
                              "TTL": 60,
                              "ResourceRecords": '$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords")'
                          }
                          }]
                      }' > /dev/null 2>&1
                  fi

                  # Create the record again
                  aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch '{
                      "Comment": "Create record",
                      "Changes": [{
                          "Action": "CREATE",
                          "ResourceRecordSet": {
                          "Name": "'$CLUSTER_NAME'",
                          "Type": "CNAME",
                          "TTL": 60,
                          "ResourceRecords": [{
                              "Value": "'$HOSTNAME'"
                          }]
                          }
                      }]
                  }' > /dev/null 2>&1

                  # Create the record again for the *.domain
                  aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch '{
                      "Comment": "Create record",
                      "Changes": [{
                          "Action": "CREATE",
                          "ResourceRecordSet": {
                          "Name": "'*.$CLUSTER_NAME'",
                          "Type": "CNAME",
                          "TTL": 60,
                          "ResourceRecords": [{
                              "Value": "'$HOSTNAME'"
                          }]
                          }
                      }]
                  }' > /dev/null 2>&1
                else
                    echo "Skipping Route53 Hostname update since it's already in sync"
                fi

                echo "apiVersion: cert-manager.io/v1
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
                          class: traefik" | kubectl apply -f -

                echo "Domain https://argocd.$CLUSTER_NAME should now be available (TTL 60)"

                sleep 2
                echo "Activating the generators..."
                kubectl get applications/generators -n argocd &> /dev/null

                # $? is a special variable that holds the exit status of the last command executed
                if [[ $? -ne 0 ]]; then
                    helm upgrade $HELM_PLATFORM platform/chart --set generators=true
                else
                    echo "Generators are active"
                fi

            exit 0

            else
                sleep 2
            fi
        done

    elif [[ "$(date +%s)" -gt "$END_TIME" ]]; then
        echo "Timed out waiting for Helm release $HELM_PLATFORM to be deployed."
        helm install platform-name platform/chart --create-namespace
    else
        sleep 7
    fi
done


