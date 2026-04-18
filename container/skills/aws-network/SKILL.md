---
name: aws-network
description: Query ALB and NLB load balancers, API Gateway stages, WAF rules and blocked requests, and EFS file systems. Use for traffic, 5xx errors, blocked IPs, target health, and API latency. Triggers on "alb", "nlb", "load balancer", "api gateway", "waf", "efs", "5xx", "target group", "blocked requests".
allowed-tools: Bash(aws elbv2:*), Bash(aws apigateway:*), Bash(aws apigatewayv2:*), Bash(aws wafv2:*), Bash(aws elasticfilesystem:*), Bash(aws cloudwatch:*)
---

# AWS Network & Edge

---

## ALB / NLB (Elastic Load Balancing v2)

### List all load balancers
```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,Type:Type,Scheme:Scheme,State:State.Code,DNS:DNSName}' \
  --output table
```

### Target group health (are targets healthy?)
```bash
# List target groups
aws elbv2 describe-target-groups \
  --query 'TargetGroups[*].{Name:TargetGroupName,Protocol:Protocol,Port:Port,LBArn:LoadBalancerArns[0]}' \
  --output table

# Health for a specific target group
aws elbv2 describe-target-health \
  --target-group-arn <arn> \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,Health:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

### ALB request count and 5xx errors (last 1h)
```bash
ALB_NAME="<alb-name>"  # just the name part, no arn

for METRIC in RequestCount HTTPCode_Target_5XX_Count HTTPCode_ELB_5XX_Count TargetResponseTime; do
  echo "=== $METRIC ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ApplicationELB \
    --metric-name "$METRIC" \
    --dimensions Name=LoadBalancer,Value="app/${ALB_NAME}/<suffix>" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum Average --output table
done
```

### ALB access logs (if enabled) — search via Athena or CloudWatch
```bash
# ALB logs are in S3 — use Athena for queries (see aws-analytics skill)
# Or check CloudWatch if access logs are forwarded there
aws logs tail "/aws/alb/<name>" --since 30m --format short 2>/dev/null || echo "ALB logs not in CloudWatch"
```

---

## API Gateway

### List REST APIs
```bash
aws apigateway get-rest-apis \
  --query 'items[*].{ID:id,Name:name,Created:createdDate,Version:version}' \
  --output table
```

### List HTTP/WebSocket APIs (v2)
```bash
aws apigatewayv2 get-apis \
  --query 'Items[*].{ID:ApiId,Name:Name,Protocol:ProtocolType,Endpoint:ApiEndpoint}' \
  --output table
```

### Stages for a REST API
```bash
aws apigateway get-stages --rest-api-id <api-id> \
  --query 'item[*].{Stage:stageName,Deployed:deploymentId,Throttle:defaultRouteSettings}' \
  --output table
```

### API Gateway 4xx/5xx errors (last 1h)
```bash
for METRIC in 4XXError 5XXError Count Latency; do
  echo "=== $METRIC ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ApiGateway \
    --metric-name "$METRIC" \
    --dimensions Name=ApiName,Value=<api-name> \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum Average --output table
done
```

---

## WAF

### List WAF Web ACLs (regional)
```bash
aws wafv2 list-web-acls --scope REGIONAL \
  --query 'WebACLs[*].{Name:Name,ID:Id,ARN:ARN}' \
  --output table
```

### Rules in a Web ACL
```bash
aws wafv2 get-web-acl --name <name> --scope REGIONAL --id <id> \
  --query 'WebACL.Rules[*].{Name:Name,Action:Action,Priority:Priority}' \
  --output table
```

### WAF blocked requests (last 1h)
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value=<acl-name> Name=Region,Value=ap-southeast-1 Name=Rule,Value=ALL \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum --output table
```

### WAF logs — search for blocked IPs (if logs enabled to S3/CloudWatch)
```bash
aws logs filter-log-events \
  --log-group-name "aws-waf-logs-<name>" \
  --start-time "$(date -d '30 minutes ago' +%s000 2>/dev/null || python3 -c 'import time; print(int((time.time()-1800)*1000))')" \
  --filter-pattern '{ $.action = "BLOCK" }' \
  --query 'events[*].message' --output text | head -20
```

---

## EFS

### List file systems with size and throughput mode
```bash
aws elasticfilesystem describe-file-systems \
  --query 'FileSystems[*].{ID:FileSystemId,Name:Name,State:LifeCycleState,SizeGB:SizeInBytes.Value,ThroughputMode:ThroughputMode,PerformanceMode:PerformanceMode}' \
  --output table
```

### Mount targets (which AZs/subnets)
```bash
aws elasticfilesystem describe-mount-targets \
  --file-system-id <fs-id> \
  --query 'MountTargets[*].{AZ:AvailabilityZoneName,IP:IpAddress,State:LifeCycleState,Subnet:SubnetId}' \
  --output table
```

### EFS I/O metrics (last 1h)
```bash
for METRIC in ClientConnections DataReadIOBytes DataWriteIOBytes PercentIOLimit; do
  echo "=== $METRIC ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name "$METRIC" \
    --dimensions Name=FileSystemId,Value=<fs-id> \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Average --output table
done
```

---

## Response format

1. For load balancers: always check target health — unhealthy targets = service degraded
2. For WAF: high BlockedRequests might mean an attack or a false positive — look at the logs
3. For API Gateway: 5XX errors should always be followed by Lambda/backend log check
