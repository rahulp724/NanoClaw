---
name: aws-compute
description: Query and operate EC2 instances, Lambda functions, EKS clusters and pods, and ECR repositories. Use for questions about servers, containers, deployments, pod health, function errors, and instance status. Triggers on "ec2", "lambda", "eks", "pods", "nodes", "deployment", "instances", "ecr", "container image".
allowed-tools: Bash(aws ec2:*), Bash(aws lambda:*), Bash(aws eks:*), Bash(aws ecr:*), Bash(kubectl:*)
---

# AWS Compute

Query EC2, Lambda, EKS, and ECR. kubeconfig is mounted at `/workspace/global/kubeconfig`.

```bash
export KUBECONFIG=/workspace/global/kubeconfig
```

---

## EC2

### List all running instances with name, type, IP
```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,Type:InstanceType,IP:PrivateIpAddress,AZ:Placement.AvailabilityZone,LaunchTime:LaunchTime}' \
  --output table
```

### Instance CPU/memory (last 1h)
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average Maximum --output table
```

### Stop / Start / Reboot instance (operational — confirm with user first)
```bash
aws ec2 stop-instances    --instance-ids <id>
aws ec2 start-instances   --instance-ids <id>
aws ec2 reboot-instances  --instance-ids <id>
```

### Security groups for an instance
```bash
aws ec2 describe-instances --instance-ids <id> \
  --query 'Reservations[*].Instances[*].SecurityGroups' --output table
```

---

## Lambda

### List all functions with runtime and last modified
```bash
aws lambda list-functions \
  --query 'Functions[*].{Name:FunctionName,Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,Modified:LastModified}' \
  --output table
```

### Function error rate (last 1h from CloudWatch)
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=<function-name> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum --output table
```

### Lambda recent logs
```bash
aws logs tail "/aws/lambda/<function-name>" --since 30m --format short
```

### Invoke a function (dry-run — no side effects)
```bash
aws lambda invoke \
  --function-name <name> \
  --invocation-type DryRun \
  --payload '{}' /tmp/lambda-out.json && cat /tmp/lambda-out.json
```

### Get function config (env vars, layers, VPC)
```bash
aws lambda get-function-configuration --function-name <name> \
  --query '{Runtime:Runtime,Handler:Handler,Timeout:Timeout,Memory:MemorySize,VPC:VpcConfig,Env:Environment}' \
  --output json
```

---

## EKS

```bash
export KUBECONFIG=/workspace/global/kubeconfig
```

### List clusters
```bash
aws eks list-clusters --query 'clusters' --output table
```

### Get cluster details
```bash
aws eks describe-cluster --name <cluster> \
  --query 'cluster.{Status:status,Version:version,Endpoint:endpoint,Logging:logging}' \
  --output json
```

### All pods (across namespaces) with status
```bash
kubectl get pods --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount'
```

### Pods in CrashLoopBackOff or Error
```bash
kubectl get pods --all-namespaces --field-selector=status.phase!=Running 2>/dev/null
kubectl get pods --all-namespaces | grep -E 'CrashLoop|Error|OOMKilled|Evicted'
```

### Describe a failing pod (shows events and last error)
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --tail=50
kubectl logs <pod-name> -n <namespace> --previous --tail=50  # previous container
```

### Node status and resource usage
```bash
kubectl get nodes -o wide
kubectl top nodes   # requires metrics-server
kubectl top pods --all-namespaces --sort-by=memory | head -20
```

### Deployment rollout status
```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl rollout history deployment/<name> -n <namespace>
```

### Restart a deployment (triggers rolling update)
```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

### Services and their external endpoints
```bash
kubectl get svc --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTERNAL-IP:.status.loadBalancer.ingress[0].hostname'
```

---

## ECR

### List repositories
```bash
aws ecr describe-repositories \
  --query 'repositories[*].{Name:repositoryName,URI:repositoryUri,PushedAt:createdAt}' \
  --output table
```

### Recent images in a repository
```bash
aws ecr describe-images \
  --repository-name <name> \
  --query 'sort_by(imageDetails, &imagePushedAt)[-5:].{Tag:imageTags[0],Pushed:imagePushedAt,SizeMB:imageSizeInBytes}' \
  --output table
```

### Scan findings for an image
```bash
aws ecr describe-image-scan-findings \
  --repository-name <name> \
  --image-id imageTag=<tag> \
  --query 'imageScanFindings.findingSeverityCounts' \
  --output table
```

---

## Response format

1. Show results as a table (most readable in Slack)
2. Flag anything unhealthy: CrashLoopBackOff pods, high CPU, Lambda errors, ECR scan findings
3. For EKS issues, always check pod logs as a follow-up step
