locals {
  karpenter_namespace = "kube-system"
  nodegroup_role_name = var.nodegroup_role_name != "" ? var.nodegroup_role_name : "${var.cluster_name}_nodegroup_role"
}

# Fetch EKS OIDC Provider data
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  url = data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer
}

# Create Karpenter Controller Policy
resource "aws_iam_policy" "karpenter_controller_policy" {
  name        = "${var.project_name}-AWSKarpenterControllerPolicy"
  path        = "/"
  description = "Policy for Karpenter Controller"
  tags = {
    Name = "${var.project_name}-AWSKarpenterControllerPolicy"
  }
  
  # Replace placeholders in the policy with actual values
  policy = replace(
    replace(
      replace(
        replace(
          file("${path.module}/karpentercontrollerpolicy.json"), 
          "$${AWS_ACCOUNT_ID}", var.aws_account_id
        ),
        "$${CLUSTER_NAME}", var.cluster_name
      ),
      "$${REGION}", var.region
    ),
    "$${PROJECT_NAME}", var.project_name
  )
}

# Karpenter Controller Role
data "aws_iam_policy_document" "karpenter_controller_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.karpenter_namespace}:karpenter"]
    }

    principals {
      identifiers = [data.aws_iam_openid_connect_provider.eks_oidc_provider.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "karpenter_controller_role" {
  name               = "${var.project_name}-KarpenterControllerRole"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role_policy.json
  tags = {
    "Name" = "${var.project_name}-KarpenterControllerRole"
  }
}

# Attach Karpenter Controller Policy to Role
resource "aws_iam_role_policy_attachment" "attach_karpenter_controller_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = aws_iam_policy.karpenter_controller_policy.arn
}

# Attach AWS managed policies to the Karpenter controller role
resource "aws_iam_role_policy_attachment" "karpenter_worker_node_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_cni_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_ecr_read_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_ssm_managed_instance_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# Add SSM capability to the node role
resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  role       = local.nodegroup_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create SQS Queue for Karpenter interruption handling
resource "aws_sqs_queue" "karpenter_interruption_queue" {
  name = var.cluster_name
  tags = {
    Name = "${var.project_name}-karpenter-interruption-queue"
  }
}

# Install Karpenter using Helm
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = local.karpenter_namespace
  create_namespace = false

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller_role.arn
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = data.aws_eks_cluster.cluster.endpoint
  }

  set {
    name  = "settings.defaultInstanceProfile"
    value = "${var.cluster_name}-KarpenterNodeInstanceProfile"
  }

  set {
    name  = "settings.interruptionQueueName"
    value = aws_sqs_queue.karpenter_interruption_queue.name
  }
}


# Create node instance profile
resource "aws_iam_instance_profile" "karpenter_instance_profile" {
  name = "${var.cluster_name}-KarpenterNodeInstanceProfile"
  role = local.nodegroup_role_name
  
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# Output important values for reference
output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller_role.arn
}

output "karpenter_instance_profile_name" {
  description = "Name of the IAM instance profile for Karpenter nodes"
  value       = aws_iam_instance_profile.karpenter_instance_profile.name
}

output "karpenter_queue_name" {
  description = "Name of the SQS queue for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter_interruption_queue.name
}

# NOTE: Manual step required!
# After applying this Terraform configuration, you must update the aws-auth ConfigMap
# to add the Karpenter role to the mapRoles section:
#
# kubectl edit configmap aws-auth -n kube-system
#
# Add the following under mapRoles:
#   - rolearn: <karpenter_controller_role_arn>
#     username: system:node:{{EC2PrivateDNSName}}
#     groups:
#     - system:bootstrappers
#     - system:nodes
