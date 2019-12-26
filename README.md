# eks-fargate-alb-ingress-sample
EKS releases support for running Kubernetes pod on Fargate in December 2019. EKS documentation mention Fargate pod can only be exposed using the ALB ingress controller. However, there was not any documentation explaining how to achieve this. This article intends to give an example on how to have pods running as Fargate pods and exposed it using an ALB ingress controller. In this sample, all pods will be running as Fargate pods, including the ALB ingress controller pod.

Prerequisites
- eksctl => 0.11.1
- awscli => 1.16.302
- kubectl => 1.14.0
- jq
- curl
- IAM role or user configured for awscli with Administrator policy


You can run the following make command to check your system configuration:
```bash
make depcheck
```

By default, the script will deploy an EKS cluster named eks-fargate in us-east-2 region. If you want to change this, modify the make file, and adjust the value of variable CLUSTER and REGION. To deploy the sample, run the following command:
```bash
make install
```

To delete all resources created through this script, execute the following command:
```bash
make clean
```

To summarize, the install action will perform the following operations:
1. Create an EKS cluster with a default Fargate profile and without any node group
2. Create an OIDC provider for the cluster in IAM
3. Deploy the required Kubernetes RBAC objects for ALB ingress controller
4. Create an IAM role and associate it to ALB ingress controller service account
5. Create a custom security group to allow inbound access to ALB and communication between ALB with Fargate pods
6. Patch manifest files required to deploy ALB ingress controller (deployment) and sample application (deployment service and ingress)
7. Deploy manifest files from the previous step

### 1. Create an EKS cluster with a default Fargate profile and without any node group

On this step, a script (cluster.sh) will call an eksctl command to create the EKS cluster with --without-nodegroup flag. This flag tells eksctl to create the cluster without any node group. The next added flag is --fargate, which will generate a default fargate profile to allow pods on namespace kube-system and default to run as Fargate pod including CoreDNS pods.

### 2. Create an OIDC provider for the created EKS cluster in IAM

Since the ALB Ingress Controller pod will use IAM Role for the service account (IRSA), we will need to enable IRSA for the created EKS Cluster by adding its Open ID Connect (OIDC) as an identity provider in the IAM service. 


### 3. Deploy the required Kubernetes RBAC objects for ALB ingress controller

This step will deploy Kubernetes RBAC resources for ALB ingress controller such as service account, cluster role, and cluster role binding. You can find the manifest file for this step under manifest/rbac-role.yaml

### 4. Create an IAM role and associate it to ALB ingress controller service account

ALB ingress controller will need to make several AWS API calls to provision ALB components for Kubernetes ingress resource type. Therefore, ALB ingress controller will need an IAM role to authenticate these API calls. In EKS, the ALB ingress controller pod can do this using the IAM role for the service account. 

On this step, we will use irsa.sh script to help create an IAM role that will be assumed by a service account on an EKS cluster using cluster's OIDC provider (sts:AssumeRoleWithWebIdentity). After creating the IAM role, irsa.sh will add annotation eks.amazonaws.com/role-arn to the existing service account to be able to assume the role. 

irsa.sh is an enhancement from eksctl create iamserviceaccount command in which it can only attach IAM policy arns. Meanwhile, irsa.sh script will be able to accept both policy arn and policy document. For more information on irsa.sh, go to [eks-irsa-helper GitHub page](https://github.com/rimaulana/eks-irsa-helper)

### 5. Create a custom security group to allow inbound access to ALB and communication between ALB with Fargate pods

By default, the ALB ingress controller will create a security group for the ALB and add this security in a policy of the worker node's security group. By doing this, it allows the communication between the ALB and the backend pods hosted on the worker nodes. 

When a pod runs as a Fargate pod, the ALB ingress controller will not be able to add its generated security group into a policy on the worker node's security group — thus causing the ALB unable to forward the connections to the backend pods. Therefore, we will need to use  **alb.ingress.kubernetes.io/security-groups** [annotation](https://kubernetes-sigs.github.io/aws-alb-ingress-controller/guide/ingress/annotation/#security-groups) on the ingress resource to stop the ALB ingress controller to generate a security group and try adding it into a policy on a worker node's security group.

With the release of new features, such as the managed node group and Fargate pod, the EKS cluster will create an additional cluster's control plane security group, and Fargate pods will use this security group on its ENI. Therefore, we will need to allow communication between the ALB security group and this additional EKS cluster's security group. By doing this, the ALB will be able to pass inbound traffic to the backend pods running as Fargate. 

In this example, we are creating a cloudformation stack to automate the provisioning of the ALB security group as well as the policy on the additional cluster's control plane security group.

### 6. Patch manifest files required to deploy ALB ingress controller (deployment) and sample application (deployment, service, and ingress)

We need to patch some manifest files before deploying it to the EKS cluster. For ALB ingress controller's deployment file (manifest/alb-ingress.controller.yaml) following are the required modifications. Under spec.template.spec.containers[0].args patch need to be applied to make the value to look like the following

```yaml
args:
- --ingress-class=alb
- --cluster-name=<CLUSTER_NAME>
- --aws-vpc-id=<VPC_ID>
- --aws-region=<AWS_REGION>
```

Why are these values important? Since pod is running on Fargate, it will not have access to the underlying EC2 instance metadata. By providing this value, the ALB ingress controller will not attempt to get these values from the underlying EC2 instance metadata. 

Another important definition is manifest/ingress.yaml; this will create the ingress resource in the EKS cluster. Since pods will run as Fargate pods, like in ECS, the only supported target type for Fargate is IP. Therefore, [annotation](https://kubernetes-sigs.github.io/aws-alb-ingress-controller/guide/ingress/annotation/#target-type) **alb.ingress.kubernetes.io/target-type: ip** on ingress manifest is a must. This annotation will work with any Kubernetes service type (ClusterIP, NodePort, and Headless). The patch script will also replace keyword SG_ID on ingress definition with the custom security group created in step 5.

### 7. Once the script patched all the required manifest files (under patched folder), the Makefile script will deploy these manifest files to the Kubernetes cluster, and at the end of the process, the script will give the URL of the application.