---
name: aws-analytics
description: Query Athena for S3-backed SQL analytics and Cognito for user pool management. Use for ad-hoc data queries, ALB/WAF log analysis, user counts, and authentication issues. Triggers on "athena", "cognito", "user pool", "query logs", "sql query", "analyze logs".
allowed-tools: Bash(aws athena:*), Bash(aws cognito-idp:*), Bash(aws s3:*), Bash(aws cloudwatch:*)
---

# AWS Analytics & Identity

---

## Athena

Athena runs SQL on S3 data (ALB logs, WAF logs, CloudTrail, custom datasets). Results are written to an S3 output location.

### List workgroups
```bash
aws athena list-work-groups \
  --query 'WorkGroups[*].{Name:Name,State:State,Description:Description}' \
  --output table
```

### List databases in a catalog
```bash
aws athena list-databases \
  --catalog-name AwsDataCatalog \
  --query 'DatabaseList[*].{Name:Name}' \
  --output table
```

### List tables in a database
```bash
aws athena list-table-metadata \
  --catalog-name AwsDataCatalog \
  --database-name <database> \
  --query 'TableMetadataList[*].{Name:Name,Type:TableType,Created:CreateTime}' \
  --output table
```

### Run a query and get results (synchronous pattern)
```bash
OUTPUT_LOCATION="s3://<your-athena-results-bucket>/athena-results/"
WORKGROUP="primary"  # or your custom workgroup name

# Start query
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT * FROM <database>.<table> LIMIT 20" \
  --work-group "$WORKGROUP" \
  --result-configuration OutputLocation="$OUTPUT_LOCATION" \
  --query 'QueryExecutionId' --output text)

echo "Query ID: $QUERY_ID"

# Poll until complete (up to 60s)
for i in $(seq 1 12); do
  sleep 5
  STATE=$(aws athena get-query-execution \
    --query-execution-id "$QUERY_ID" \
    --query 'QueryExecution.Status.State' --output text)
  echo "State: $STATE"
  if [ "$STATE" = "SUCCEEDED" ]; then break; fi
  if [ "$STATE" = "FAILED" ] || [ "$STATE" = "CANCELLED" ]; then
    aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --query 'QueryExecution.Status.StateChangeReason' --output text
    exit 1
  fi
done

# Get results
aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output text | head -50
```

### Query ALB access logs (if table exists in Athena)
```bash
# Typical ALB log table query — count 5xx by target IP in last hour
OUTPUT_LOCATION="s3://<results-bucket>/athena-results/"
QUERY="
SELECT client_ip, target_ip, elb_status_code, COUNT(*) as count
FROM <database>.alb_logs
WHERE from_iso8601_timestamp(time) > now() - interval '1' hour
  AND elb_status_code >= 500
GROUP BY client_ip, target_ip, elb_status_code
ORDER BY count DESC
LIMIT 20"

QUERY_ID=$(aws athena start-query-execution \
  --query-string "$QUERY" \
  --result-configuration OutputLocation="$OUTPUT_LOCATION" \
  --query 'QueryExecutionId' --output text)

for i in $(seq 1 12); do
  sleep 5
  STATE=$(aws athena get-query-execution --query-execution-id "$QUERY_ID" \
    --query 'QueryExecution.Status.State' --output text)
  [ "$STATE" = "SUCCEEDED" ] && break
done
aws athena get-query-results --query-execution-id "$QUERY_ID" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' --output text
```

### Query WAF logs (blocked IPs in last hour)
```bash
OUTPUT_LOCATION="s3://<results-bucket>/athena-results/"
QUERY="
SELECT httprequest.clientip, COUNT(*) as blocked_count
FROM <database>.waf_logs
WHERE action = 'BLOCK'
  AND from_unixtime(timestamp/1000) > now() - interval '1' hour
GROUP BY httprequest.clientip
ORDER BY blocked_count DESC
LIMIT 20"

QUERY_ID=$(aws athena start-query-execution \
  --query-string "$QUERY" \
  --result-configuration OutputLocation="$OUTPUT_LOCATION" \
  --query 'QueryExecutionId' --output text)

for i in $(seq 1 12); do
  sleep 5
  STATE=$(aws athena get-query-execution --query-execution-id "$QUERY_ID" \
    --query 'QueryExecution.Status.State' --output text)
  [ "$STATE" = "SUCCEEDED" ] && break
done
aws athena get-query-results --query-execution-id "$QUERY_ID" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' --output text
```

### Recent query history (last 10)
```bash
aws athena list-query-executions --max-results 10 \
  --query 'QueryExecutionIds' --output text | tr '\t' '\n' | while read ID; do
  aws athena get-query-execution --query-execution-id "$ID" \
    --query 'QueryExecution.{ID:QueryExecutionId,State:Status.State,Submitted:Status.SubmissionDateTime,Duration:Statistics.TotalExecutionTimeInMillis,Query:Query}' \
    --output json 2>/dev/null
done | jq -s '.'
```

---

## Cognito

### List all user pools
```bash
aws cognito-idp list-user-pools --max-results 60 \
  --query 'UserPools[*].{ID:Id,Name:Name,Created:CreationDate,LastModified:LastModifiedDate}' \
  --output table
```

### User pool details (MFA, password policy, triggers)
```bash
aws cognito-idp describe-user-pool --user-pool-id <pool-id> \
  --query 'UserPool.{Name:Name,Status:Status,MFA:MfaConfiguration,EstimatedUsers:EstimatedNumberOfUsers,Schema:SchemaAttributes[*].Name}' \
  --output json
```

### List users in a pool (first 60)
```bash
aws cognito-idp list-users \
  --user-pool-id <pool-id> \
  --limit 60 \
  --query 'Users[*].{Username:Username,Status:UserStatus,Enabled:Enabled,Created:UserCreateDate,Email:Attributes[?Name==`email`].Value|[0]}' \
  --output table
```

### Find a specific user
```bash
aws cognito-idp admin-get-user \
  --user-pool-id <pool-id> \
  --username <username-or-email> \
  --query '{Username:Username,Status:UserStatus,Enabled:Enabled,Attributes:UserAttributes,Created:UserCreateDate,Modified:UserLastModifiedDate}' \
  --output json
```

### Search users by email
```bash
aws cognito-idp list-users \
  --user-pool-id <pool-id> \
  --filter 'email = "<email>"' \
  --query 'Users[*].{Username:Username,Status:UserStatus,Email:Attributes[?Name==`email`].Value|[0]}' \
  --output table
```

### List user groups
```bash
aws cognito-idp list-groups --user-pool-id <pool-id> \
  --query 'Groups[*].{Name:GroupName,Description:Description,Precedence:Precedence}' \
  --output table
```

### Users in a specific group
```bash
aws cognito-idp list-users-in-group \
  --user-pool-id <pool-id> \
  --group-name <group-name> \
  --query 'Users[*].{Username:Username,Status:UserStatus,Email:Attributes[?Name==`email`].Value|[0]}' \
  --output table
```

### User pool sign-in metrics (CloudWatch)
```bash
for METRIC in SignInSuccesses SignUpSuccesses TokenRefreshSuccesses ForgotPasswordSuccesses; do
  echo "=== $METRIC ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Cognito \
    --metric-name "$METRIC" \
    --dimensions Name=UserPool,Value=<pool-id> Name=UserPoolClient,Value=<client-id> \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --output table
done
```

### Admin: disable / enable a user
```bash
# Disable
aws cognito-idp admin-disable-user --user-pool-id <pool-id> --username <username>

# Enable
aws cognito-idp admin-enable-user --user-pool-id <pool-id> --username <username>
```

### Reset a user's password (force change on next login)
```bash
aws cognito-idp admin-reset-user-password --user-pool-id <pool-id> --username <username>
```

---

## Response format

1. For Athena: always show query state and duration — a FAILED query needs the StateChangeReason
2. For Cognito: always show UserStatus (CONFIRMED / UNCONFIRMED / FORCE_CHANGE_PASSWORD) and Enabled flag
3. For sign-in metrics: high failure rates may indicate an attack or a broken client
