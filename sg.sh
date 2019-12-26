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
    echo "usage: $0 [create|delete] [options]"
    echo "Create security group allowing commication to ALB and from ALB to Fargate pods"
    echo ""
    echo "-h,--help print this help"
    echo "--cluster The name of the EKS cluster. (default: eks-fargate)"
    echo "--region The EKS cluster region. (default: us-east-2)"
    echo "--allowed-cidr The IP CIDR range to be allowed inbound access to ALB on port 80 and 443. (default: 0.0.0.0/0)"
}


POSITIONAL=()

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
        --allowed-cidr)
            ALLOWED_CIDR=$2
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
ALLOWED_CIDR="${ALLOWED_CIDR:-0.0.0.0/0}"
STACKNAME="alb-securitygroup-$CLUSTER_NAME-$REGION"

function log(){
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

function create_stack() {
    QUERY=$(aws eks describe-cluster \
        --name $CLUSTER_NAME \
        --region $REGION 2>&1)
        
    VPC_ID=$(echo $QUERY | jq -r '.cluster.resourcesVpcConfig.vpcId')
    FARGATE_SGID=$(echo $QUERY | jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')
    
    if [[ -z $VPC_ID ]]; then
        log "No VPC ID found, exiting"
        exit 1;
    else
        log "Found VPCID $VPC_ID"
    fi
    
    # ENI_LIST=$(aws ec2 describe-network-interfaces \
    #     --filters \
    #         Name=vpc-id,Values=$VPC_ID \
    #         Name=status,Values=in-use \
    #     --region $REGION)
    
    # FARGATE_SGID=""
    
    # for row in $(echo "${ENI_LIST}" | jq -r '.NetworkInterfaces[] | @base64'); do
    #     _jq() {
    #      echo ${row} | base64 --decode | jq -r ${1}
    #     }
    #     if [[ $(_jq '.RequesterId') =~ .*\:eks-fargate-assume-role$ ]]; then
    #         FARGATE_SGID=$(_jq '.Groups[0].GroupId')
    #         break
    #     fi
    # done
    
    if [[ -z $FARGATE_SGID ]]; then
        log "No Fargate security group found, exiting"
        exit 1;
    else
        log "Found Fargate security group $FARGATE_SGID"
    fi
    
    aws cloudformation deploy \
        --template-file ingress-sg.yaml \
        --stack-name $STACKNAME \
    	--region $REGION \
    	--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    	--parameter-overrides ClusterName=$CLUSTER_NAME VPCID=$VPC_ID FargateSGID=$FARGATE_SGID AllowedCIDR=$ALLOWED_CIDR
    
    aws cloudformation describe-stacks \
        --stack-name $STACKNAME \
        --region $REGION \
        --query Stacks[0].Outputs[0].OutputValue \
        --output text > sg.id
}

function delete_stack() {
    aws cloudformation delete-stack \
        --stack-name $STACKNAME \
    	--region $REGION 
    
    aws cloudformation wait stack-delete-complete \
        --stack-name $STACKNAME \
    	--region $REGION
}

case $OPERATION in 
    create)
        create_stack
        ;;
    delete)
        delete_stack
        ;;
    *)
        log "Operation $OPERATION does not exist, exiting"
        exit 1
        ;;
esac