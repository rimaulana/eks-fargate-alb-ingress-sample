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
    echo "usage: $0 [options] [path to manifest_files]"
    echo "Patch deployment file with cluster related information"
    echo ""
    echo "-h,--help print this help"
    echo "--cluster The name of the EKS cluster. (default: eks-fargate)"
    echo "--region The EKS cluster region. (default: us-east-2)"
}

POSITIONAL=()
MANIFEST=()

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
            MANIFEST+=("$1")
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters

CLUSTER_NAME="${CLUSTER_NAME:-eks-fargate}"
REGION="${REGION:-us-east-2}"

VPC_ID=$(aws eks describe-cluster \
                       --name $CLUSTER_NAME \
                       --query cluster.resourcesVpcConfig.vpcId \
                       --region $REGION \
                       --output text)

SG_ID=$(cat sg.id)

if [[ -z $SG_ID || -z $VPC_ID ]]; then
  log "No VPC ID or security group id found, exiting"
  exit 1;
fi

mkdir -p patched

for manifest_file in "${MANIFEST[@]}"
do
  NEW_NAME="patched/$(basename $manifest_file)"
  sed -e s,CLUSTER_NAME,$CLUSTER_NAME,g $manifest_file > patched/patched.cluster
  sed -e s,REGION,$REGION,g patched/patched.cluster > patched/patched.region
  sed -e s,VPC_ID,$VPC_ID,g patched/patched.region > patched/patched.vpc
  sed -e s,SG_ID,$SG_ID,g patched/patched.vpc > $NEW_NAME
  rm -f patched/patched.vpc patched/patched.region patched/patched.cluster patched/patched.region
done

