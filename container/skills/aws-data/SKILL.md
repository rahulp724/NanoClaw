---
name: aws-data
description: Query RDS Aurora clusters, Valkey/ElastiCache, SQS queues, SNS topics, and S3 buckets. Use for database health, cache hit rates, queue depths, message backlog, and storage usage. Triggers on "rds", "aurora", "database", "valkey", "redis", "elasticache", "sqs", "queue", "sns", "topic", "s3", "bucket".
allowed-tools: Bash(aws rds:*), Bash(aws elasticache:*), Bash(aws sqs:*), Bash(aws sns:*), Bash(aws s3:*), Bash(aws s3api:*), Bash(aws cloudwatch:*)
---

# AWS Data Services

---

## RDS Aurora

### List all DB clusters with status and engine
```bash
aws rds describe-db-clusters \
  --query 'DBClusters[*].{ID:DBClusterIdentifier,Status:Status,Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZ,Writer:DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier|[0]}' \
  --output table
```

### Cluster endpoints (writer + reader)
```bash
aws rds describe-db-clusters \
  --query 'DBClusters[*].{Cluster:DBClusterIdentifier,Writer:Endpoint,Reader:ReaderEndpoint,Port:Port}' \
  --output table
```

### Instance health (all DB instances)
```bash
aws rds describe-db-instances \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Class:DBInstanceClass,Status:DBInstanceStatus,Storage:AllocatedStorage,FreeStorage:Endpoint.Address}' \
  --output table
```

### Key metrics (last 1h)
```bash
# CPU
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBClusterIdentifier,Value=<cluster> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average --output table

# Connections
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=<cluster> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average Maximum --output table
```

### Aurora error logs (last 30 min)
```bash
aws logs tail "/aws/rds/cluster/<cluster>/error" --since 30m --format short 2>/dev/null \
  || aws logs filter-log-events \
       --log-group-name "/aws/rds/cluster/<cluster>/error" \
       --start-time "$(date -d '30 minutes ago' +%s000 2>/dev/null || python3 -c 'import time; print(int((time.time()-1800)*1000))')" \
       --query 'events[*].message' --output text
```

### Pending maintenance
```bash
aws rds describe-pending-maintenance-actions \
  --query 'PendingMaintenanceActions[*].{Resource:ResourceIdentifier,Action:PendingMaintenanceActionDetails[0].Action,ApplyBy:PendingMaintenanceActionDetails[0].ForcedApplyDate}' \
  --output table
```

---

## Valkey / ElastiCache

### List all clusters (Valkey, Redis, Memcached)
```bash
aws elasticache describe-cache-clusters \
  --show-cache-node-info \
  --query 'CacheClusters[*].{ID:CacheClusterId,Engine:Engine,Version:EngineVersion,Status:CacheClusterStatus,NodeType:CacheNodeType,Endpoint:CacheNodes[0].Endpoint.Address}' \
  --output table
```

### Replication groups (multi-node / cluster mode)
```bash
aws elasticache describe-replication-groups \
  --query 'ReplicationGroups[*].{ID:ReplicationGroupId,Status:Status,MultiAZ:MultiAZ,NodeGroups:NodeGroups[0].PrimaryEndpoint.Address}' \
  --output table
```

### Cache hit rate and connections (last 1h)
```bash
for METRIC in CacheHits CacheMisses CurrConnections CPUUtilization; do
  echo "=== $METRIC ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ElastiCache --metric-name "$METRIC" \
    --dimensions Name=CacheClusterId,Value=<cluster-id> \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Average --output table
done
```

---

## SQS

### All queues with depth and oldest message age
```bash
# List all queue URLs
QUEUES=$(aws sqs list-queues --query 'QueueUrls' --output text)

for Q in $QUEUES; do
  NAME=$(echo "$Q" | awk -F/ '{print $NF}')
  ATTRS=$(aws sqs get-queue-attributes --queue-url "$Q" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
                      ApproximateAgeOfOldestMessage --output json)
  DEPTH=$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages')
  AGE=$(echo "$ATTRS"   | jq -r '.Attributes.ApproximateAgeOfOldestMessage')
  echo "$NAME  depth=$DEPTH  oldest=${AGE}s"
done
```

### Dead letter queue depth
```bash
aws sqs get-queue-attributes \
  --queue-url <dlq-url> \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text
```

### Purge a queue (irreversible — confirm with user)
```bash
aws sqs purge-queue --queue-url <queue-url>
```

---

## SNS

### List topics
```bash
aws sns list-topics --query 'Topics[*].TopicArn' --output table
```

### Topic subscriptions
```bash
aws sns list-subscriptions-by-topic --topic-arn <arn> \
  --query 'Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}' \
  --output table
```

### Delivery failures (CloudWatch)
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/SNS --metric-name NumberOfNotificationsFailed \
  --dimensions Name=TopicName,Value=<topic-name> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum --output table
```

---

## S3

### All buckets with region and versioning
```bash
aws s3api list-buckets \
  --query 'Buckets[*].{Name:Name,Created:CreationDate}' \
  --output table
```

### Bucket size and object count (from CloudWatch Storage metrics)
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value=<bucket> Name=StorageType,Value=StandardStorage \
  --start-time "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 86400 --statistics Average --output table
```

### List objects in a prefix (top-level)
```bash
aws s3 ls s3://<bucket>/<prefix>/ --human-readable --summarize 2>/dev/null | tail -5
```

### Bucket policy
```bash
aws s3api get-bucket-policy --bucket <bucket> --query Policy --output text | python3 -m json.tool
```

---

## Response format

1. Lead with the health status (green / degraded / red)
2. For SQS: always show queue depth — a growing DLQ is an incident
3. For RDS: show connection count and CPU together
4. For S3: avoid listing individual objects unless explicitly asked (can be huge)
