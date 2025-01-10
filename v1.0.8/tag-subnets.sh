#!/bin/bash

CLUSTER_NAME="your-cluster-name"  # Replace with your cluster name

# List nodegroups
NODEGROUPS=$(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --query 'nodegroups' --output text)

# Loop through each nodegroup
for NODEGROUP in $NODEGROUPS; do
    # Get subnets for the nodegroup
    SUBNETS=$(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name $NODEGROUP --query 'nodegroup.subnets' --output text)
    
    # Loop through each subnet and add the tag
    for SUBNET in $SUBNETS; do
        aws ec2 create-tags --resources $SUBNET --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
        
        # Check if the tagging was successful
        if [ $? -eq 0 ]; then
            echo "Successfully tagged subnet $SUBNET with karpenter.sh/discovery=${CLUSTER_NAME}"
        else
            echo "Failed to tag subnet $SUBNET"
        fi
    done
done
