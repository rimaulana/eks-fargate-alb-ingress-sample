#!/bin/bash

# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function print_help {
    echo "usage: $0 [create | delete] [options]"
    echo ""
    echo "-h,--help print this help"
    echo "--cluster The name of the EKS cluster. (default: eks-fargate)"
    echo "--region The EKS cluster region. (default: us-east-2)"
}

POSITIONAL=()

function log(){
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

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

function create_cluster(){
    RESULT=$(aws eks describe-cluster \
                --name $CLUSTER_NAME \
                --query cluster.identity.oidc.issuer \
                --region $REGION \
                --output text 2>&1)
    
    if [[ $RESULT =~ .*ResourceNotFoundException.* ]]; then
        log "Creating cluster $CLUSTER_NAME in region $REGION"
        eksctl create cluster --name $CLUSTER_NAME --region $REGION --fargate --without-nodegroup;
        
        log "Creating OIDC provider for EKS cluster $CLUSTER_NAME"
        eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --region $REGION --approve;
        
    elif [[ $RESULT =~ .*error.* ]]; then
        # Any error should be printed out and exit the process
        log $RESULT
        exit 1;
    else
        ISSUER_HOSTPATH=$(echo $RESULT | cut -f 3- -d'/')
        EXIST=$(aws iam list-open-id-connect-providers 2>&1 | grep $ISSUER_HOSTPATH)
        if [[ -z $EXIST ]]; then
            log "OIDC Provider for $CLUSTER_NAME doesn't exist in IAM, creating"
            eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve;
        fi
    fi
}

function delete_cluster(){
    log "Trying to delete cluster"
    RESULT=$(aws eks describe-cluster \
                --name $CLUSTER_NAME \
                --query cluster.identity.oidc.issuer \
                --region $REGION \
                --output text 2>&1)
    
    if [[ $RESULT =~ .*ResourceNotFoundException.* ]]; then
        log "Cluster $CLUSTER_NAME in region $REGION doesn't exits, nothing to delete"
    elif [[ $RESULT =~ .*error.* ]]; then
        # Any error should be printed out and exit the process
        log $RESULT
        exit 1;
    else
        eksctl delete cluster --name $CLUSTER_NAME --region $REGION;
    fi
}

case $OPERATION in 
    create)
        create_cluster
        ;;
    delete)
        delete_cluster
        ;;
    *)
        log "Operation $OPERATION does not exist, exiting"
        exit 1
        ;;
esac