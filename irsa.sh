#!/bin/bash

# Copyright 2019 Rio Maulana

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# source: https://github.com/rimaulana/eks-irsa-helper

function print_help {
    echo "usage: $0 [ensure|delete] [options]"
    echo "Associate a service account with an IAM policy documents or IAM managed policy arns"
    echo ""
    echo "-h,--help print this help"
    echo "--cluster The name of the EKS cluster. (default: eks-fargate)"
    echo "--region The EKS cluster region. (default: us-east-2)"
    echo "--sa-name The name of the service account. (default: alb-ingress-controller)"
    echo "--namespace The namespace of the service account. (default: kube-system)"
    echo "--policy-document The name of the policy document file, can be use multiple times, if it is a URL, it will be downloaded first. For local file, use the file path without any file:// prefix"
    echo "--policy-arn the arn of managed policy, can be use multiple times"
}

POSITIONAL=()
POLICY_DOCUMENTS=()
POLICY_ARNS=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift
            shift
            ;;
        --region)
            REGION=$2
            shift
            shift
            ;;
        --sa-name)
            SERVICE_ACCOUNT_NAME=$2
            shift
            shift
            ;;
        --namespace)
            SERVICE_ACCOUNT_NAMESPACE=$2
            shift
            shift
            ;;
        --policy-document)
            POLICY_DOCUMENTS+=("$2")
            shift
            shift
            ;;
        --policy-arn)
            POLICY_ARNS+=("$2")
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
OPERATION="$1"

CLUSTER_NAME="${CLUSTER_NAME:-eks-fargate}"
REGION="${REGION:-us-east-2}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-alb-ingress-controller}"
SERVICE_ACCOUNT_NAMESPACE="${SERVICE_ACCOUNT_NAMESPACE:-kube-system}"
ROLE_NAME="sa-$SERVICE_ACCOUNT_NAME-in-$CLUSTER_NAME-$REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)


log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

function clean_policies_association() {
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $ROLE_NAME)
  
    for row in $(echo "${ATTACHED_POLICIES}" | jq -r '.AttachedPolicies[] | @base64'); do
        _jq() {
            echo ${row} | base64 --decode | jq -r ${1}
        }
        aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $(_jq '.PolicyArn')
    done
  
    ROLE_POLICIES=$(aws iam list-role-policies --role-name $ROLE_NAME)
  
    for row in $(echo "${ROLE_POLICIES}" | jq -r '.PolicyNames[]'); do
        aws iam delete-role-policy --role-name $ROLE_NAME --policy-name $row
    done
}

function ensure_irsa() {
    log "Populating $CLUSTER_NAME properties using describe cluster API call"
  
    ISSUER_URL=$(aws eks describe-cluster \
                    --name $CLUSTER_NAME \
                    --query cluster.identity.oidc.issuer \
                    --region $REGION \
                    --output text)
                         
    ISSUER_HOSTPATH=$(echo $ISSUER_URL | cut -f 3- -d'/')
  
    log "Getting current AWS account ID"
  
    PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"
  
    cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${ISSUER_HOSTPATH}:sub": "system:serviceaccount:$SERVICE_ACCOUNT_NAMESPACE:$SERVICE_ACCOUNT_NAME"
        }
      }
    }
  ]
}
EOF
  
    log "Creating role"
    RESULT=$(aws iam create-role \
                --role-name $ROLE_NAME \
                --assume-role-policy-document file://trust-policy.json 2>&1)
  
    if [[ $RESULT =~ .*EntityAlreadyExists.* ]]; then
        log "Role arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME exists"
        log "Updating role trust relationships"
        aws iam update-assume-role-policy \
            --role-name $ROLE_NAME \
            --policy-document file://trust-policy.json
        log "Trust relationships updated"
    
    elif [[ $RESULT =~ .*error.* ]]; then
        # Any error should be printed out and exit the process
        log $RESULT
        exit 1;
    else
        log "Role arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME created"
    fi
            
    log "Adding inline policies to the role"
  
    ROLE_POLICIES=$(aws iam list-role-policies --role-name $ROLE_NAME)
  
    POLICY_NUMBER=1
    TIMESTAMP=$(date +%s)
    for document in "${POLICY_DOCUMENTS[@]}" 
    do
        if [[ "$document" =~ ^(http|https):\/\/ ]]; then
            log "Downloading policy document from $document"
            curl --silent $document > downloaded-iam-policy.json
            DOC_NAME=downloaded-iam-policy.json
        else
            DOC_NAME=$document
        fi

        aws iam put-role-policy \
            --role-name $ROLE_NAME \
            --policy-name "$SERVICE_ACCOUNT_NAME-policy-$TIMESTAMP-$POLICY_NUMBER" \
            --policy-document file://$DOC_NAME
      
        POLICY_NUMBER=$((POLICY_NUMBER+1))
        if [[ $DOC_NAME = "downloaded-iam-policy.json" ]]; then
            rm -f downloaded-iam-policy.json
        fi
    done
  
    log "Cleaning up old inline policies (if exists)"
  
    for row in $(echo "${ROLE_POLICIES}" | jq -r '.PolicyNames[]'); do
        aws iam delete-role-policy --role-name $ROLE_NAME --policy-name $row
    done
  
    ATTACHED_POLICIES_RAW=$(aws iam list-attached-role-policies --role-name $ROLE_NAME)
    ATTACHED_POLICIES=()
  
    for row in $(echo "${ATTACHED_POLICIES_RAW}" | jq -r '.AttachedPolicies[] | @base64'); do
        _jq() {
            echo ${row} | base64 --decode | jq -r ${1}
        }
        ATTACHED_POLICIES+=("$(_jq '.PolicyArn')")
    done
  
    TO_BE_ADDED=()
  
    for item1 in "${POLICY_ARNS[@]}"; do
        for item2 in "${ATTACHED_POLICIES[@]}"; do
            [[ $item1 == "$item2" ]] && continue 2
        done

        # If we reached here, nothing matched.
        TO_BE_ADDED+=( "$item1" )
    done
  
    log "Adding managed policies to the role"
  
    for arn in "${TO_BE_ADDED[@]}"
    do
        aws iam attach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn $arn
    done
  
    TO_BE_REMOVED=()
  
    for item1 in "${ATTACHED_POLICIES[@]}"; do
        for item2 in "${POLICY_ARNS[@]}"; do
            [[ $item1 == "$item2" ]] && continue 2
        done

        # If we reached here, nothing matched.
        TO_BE_REMOVED+=( "$item1" )
    done
  
    log "Cleaning unused managed policies (if exists)"
    for arn in "${TO_BE_REMOVED[@]}"
    do
        aws iam detach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn $arn
    done
  
    ALB_INGRESS_ROLE_ARN=$(aws iam get-role \
                            --role-name $ROLE_NAME \
                            --query Role.Arn --output text)
  
    rm -f trust-policy.json
  
    log "Associating IAM Role with service account $SERVICE_ACCOUNT_NAME in $SERVICE_ACCOUNT_NAMESPACE namespace"
  
    kubectl annotate sa -n $SERVICE_ACCOUNT_NAMESPACE $SERVICE_ACCOUNT_NAME eks.amazonaws.com/role-arn=$ALB_INGRESS_ROLE_ARN --overwrite
  
    echo;
}

function delete_irsa() {
    log "Removing annotation on service account $SERVICE_ACCOUNT_NAME in namespace $SERVICE_ACCOUNT_NAMESPACE"
  
    kubectl annotate sa -n $SERVICE_ACCOUNT_NAMESPACE $SERVICE_ACCOUNT_NAME eks.amazonaws.com/role-arn- --overwrite
  
    log "Deleting IAM role $ROLE_NAME"
  
    RESULT=$(aws iam get-role \
                --role-name $ROLE_NAME 2>&1)
  
    if [[ $RESULT =~ .*NoSuchEntity.* ]]; then
        log "Role arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME does not exists, nothing to delete"
    elif [[ $RESULT =~ .*error.* ]]; then
        # Any error should be printed out and exit the process
        log $RESULT
        exit 1;
    else
        log "Detaching and deleting any associated policies"
    
        clean_policies_association
    
        aws iam delete-role --role-name $ROLE_NAME
    
        log "Role arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME deleted"
    fi
}

case $OPERATION in 
    ensure)
        ensure_irsa
        ;;
    delete)
        delete_irsa
        ;;
    *)
        echo "Operation $OPERATION does not exist, exiting"
        exit 1
        ;;
esac