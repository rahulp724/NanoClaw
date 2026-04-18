---
name: aws-observability
description: Query CloudWatch alarms, metrics, and log groups. Use for questions about alerts, errors in logs, service health, latency, and operational monitoring. Triggers on "alarms", "logs", "metrics", "cloudwatch", "errors", "latency", "health check".
allowed-tools: Bash(aws cloudwatch:*), Bash(aws logs:*)
---

# AWS Observability

Query CloudWatch alarms, metrics, and log groups. All commands use the AWS CLI
with IAM role credentials — no keys needed.

## Setup check
```bash
aws sts get-caller-identity --query Account --output text
```

---

## CloudWatch Alarms

### All alarms in ALARM state (most useful first question)
```bash
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --query 'MetricAlarms[*].{Name:AlarmName,Metric:MetricName,Namespace:Namespace,Reason:StateReason}' \
  --output table
```

### All alarms (any state) with current state
```bash
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Metric:MetricName,Updated:StateUpdatedTimestamp}' \
  --output table | sort
```

### Alarm history for a specific alarm
```bash
aws cloudwatch describe-alarm-history \
  --alarm-name "<alarm-name>" \
  --history-item-type StateUpdate \
  --max-records 10 \
  --query 'AlarmHistoryItems[*].{Time:Timestamp,Summary:HistorySummary}' \
  --output table
```

### Alarms for a specific service/resource (filter by prefix)
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "<prefix>" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --output table
```

---

## CloudWatch Metrics

### Get a specific metric (last 1 hour, 5-min periods)
```bash
aws cloudwatch get-metric-statistics \
  --namespace "<namespace>" \
  --metric-name "<metric>" \
  --dimensions Name=<dim-name>,Value=<dim-value> \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Average Maximum \
  --output table
```

### Common namespaces
- `AWS/EC2` — CPUUtilization, NetworkIn, NetworkOut
- `AWS/RDS` — CPUUtilization, DatabaseConnections, FreeStorageSpace, ReadLatency, WriteLatency
- `AWS/ApplicationELB` — RequestCount, TargetResponseTime, HTTPCode_Target_5XX_Count
- `AWS/Lambda` — Duration, Errors, Throttles, ConcurrentExecutions
- `AWS/SQS` — NumberOfMessagesSent, ApproximateNumberOfMessagesVisible, ApproximateAgeOfOldestMessage
- `AWS/ElastiCache` — CPUUtilization, CacheHits, CacheMisses, CurrConnections
- `AWS/EKS` — (use Container Insights namespace `ContainerInsights`)

---

## CloudWatch Log Groups

### List all log groups (with size and retention)
```bash
aws logs describe-log-groups \
  --query 'logGroups[*].{Name:logGroupName,RetentionDays:retentionInDays,StoredMB:storedBytes}' \
  --output table
```

### Search logs for errors (last 30 minutes)
```bash
aws logs filter-log-events \
  --log-group-name "<log-group>" \
  --start-time "$(date -d '30 minutes ago' +%s000 2>/dev/null || python3 -c 'import time; print(int((time.time()-1800)*1000))')" \
  --filter-pattern "ERROR" \
  --query 'events[*].{Time:timestamp,Message:message}' \
  --output table
```

### Tail recent log events (last N lines)
```bash
aws logs tail "<log-group>" --since 30m --format short
```

### Run a CloudWatch Logs Insights query
```bash
# Start the query
QUERY_ID=$(aws logs start-query \
  --log-group-name "<log-group>" \
  --start-time "$(date -d '1 hour ago' +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()-3600))')" \
  --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 20' \
  --query 'queryId' --output text)

# Wait and get results (poll up to 30s)
for i in $(seq 1 6); do
  sleep 5
  STATUS=$(aws logs get-query-results --query-id "$QUERY_ID" --query 'status' --output text)
  if [ "$STATUS" = "Complete" ]; then
    aws logs get-query-results --query-id "$QUERY_ID" \
      --query 'results[*][*].{k:field,v:value}' --output json
    break
  fi
done
```

### Common log group patterns
- `/aws/lambda/<function-name>` — Lambda function logs
- `/aws/rds/cluster/<cluster>/error` — RDS Aurora error logs
- `/aws/eks/<cluster>/cluster` — EKS control plane logs
- `/aws/apigateway/<api-id>` — API Gateway access logs
- `<ecs-cluster>/<service>/<container>` — ECS container logs
- `/aws/waf/logs/<name>` — WAF logs

---

## Response format

Always:
1. Show the raw result first (table or JSON)
2. Summarize what's notable (alarms firing, error rate, anomalies)
3. If alarms are firing, offer to look at the related logs or metrics
