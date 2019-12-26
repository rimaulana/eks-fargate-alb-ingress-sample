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

SHELL = /bin/bash

CLUSTER ?= eks-fargate
REGION ?= us-east-2
START = $(shell date +%s)

.PHONY: depcheck
.SILENT: depcheck
depcheck:
	echo "aws-cli: $(shell aws --version)";
	echo "jq: $(shell jq --version)";
	echo "curl: $(shell curl --version | awk 'NR==1')";
	echo "eksctl: $(shell eksctl version)";
	echo "kubectl: $(shell kubectl version --client=true --short)";
	echo "Current AWS IAM: $(shell aws sts get-caller-identity | jq -r '.Arn')";
	echo;

.PHONY: cluster-create
cluster-create:
	echo $(START) > start.time
	bash cluster.sh create --cluster $(CLUSTER) --region $(REGION)
	
.PHONY: rbac-deploy
rbac-deploy: cluster-create
	kubectl apply -f manifest/rbac-role.yaml;

.PHONY: irsa-create
irsa-create: rbac-deploy
	bash irsa.sh ensure --cluster $(CLUSTER) --region $(REGION) --sa-name alb-ingress-controller --namespace kube-system --policy-document iam-policy.json;

.PHONY: sg-create
sg-create: irsa-create
	bash sg.sh create --cluster $(CLUSTER) --region $(REGION) --allowed-cidr 0.0.0.0/0;

.PHONY: patch
patch: sg-create
	bash patch.sh --cluster $(CLUSTER) --region $(REGION) manifest/alb-ingress-controller.yaml manifest/deployment.yaml manifest/service.yaml manifest/ingress.yaml;

.PHONY: deploy 
deploy: patch
	kubectl apply -f patched/alb-ingress-controller.yaml;
	kubectl apply -f patched/deployment.yaml;
	kubectl apply -f patched/service.yaml;
	kubectl apply -f patched/ingress.yaml;

.PHONY: install
.SILENT: install
install: deploy
	bash check_serving.sh
	bash time.sh

.PHONY: delete-deployment
.SILENT: delete-deployment
delete-deployment:
	kubectl delete -f manifest/ingress.yaml --ignore-not-found=true;
	echo "Waiting for ingress to be deleted"
	sleep 10;
	kubectl delete -f manifest/service.yaml --ignore-not-found=true;
	kubectl delete -f manifest/deployment.yaml --ignore-not-found=true;
	kubectl delete -f manifest/alb-ingress-controller.yaml --ignore-not-found=true;
	rm -rf patched;

.PHONY: sg-delete
sg-delete: delete-deployment
	bash sg.sh delete --cluster $(CLUSTER) --region $(REGION);
	rm -f sg.id

.PHONY: irsa-delete
irsa-delete: sg-delete
	bash irsa.sh delete --cluster $(CLUSTER) --region $(REGION) --sa-name alb-ingress-controller --namespace kube-system;

.PHONY: rbac-delete
rbac-delete:irsa-delete
	kubectl delete -f manifest/rbac-role.yaml --ignore-not-found=true;

.PHONY: cluster-delete
cluster-delete: rbac-delete
	bash cluster.sh delete --cluster $(CLUSTER) --region $(REGION)

.PHONY: clean
clean: cluster-delete 
