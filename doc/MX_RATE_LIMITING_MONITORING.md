# MX Rate Limiting Monitoring & Alerting Guide

This guide provides best practices for monitoring and alerting on MX rate limiting in Postal, enabling proactive detection and response to mail delivery issues.

## Table of Contents

1. [Overview](#overview)
2. [Key Metrics](#key-metrics)
3. [Monitoring Implementation](#monitoring-implementation)
4. [Alerting Rules](#alerting-rules)
5. [Dashboard Setup](#dashboard-setup)
6. [Log Analysis](#log-analysis)
7. [Troubleshooting](#troubleshooting)

## Overview

MX rate limiting monitors mail server responsiveness and automatically backs off when problems are detected. Monitoring these metrics helps:

- **Detect delivery issues early** - Know when MX servers are struggling before users complain
- **Identify problem providers** - Track which mail providers are having recurring issues
- **Measure system health** - Understand your mail delivery reliability
- **Optimize configuration** - Fine-tune rate limiting parameters based on observed patterns
- **Prevent escalation** - Respond to issues before they impact delivery SLA

## Key Metrics

### Primary Metrics

| Metric | Type | Threshold | Meaning |
|--------|------|-----------|---------|
| `active_rate_limits` | Gauge | >5-10 | Multiple MX domains are experiencing issues |
| `max_delay` | Gauge | >1800s | Some servers have been backed off for >30 minutes |
| `errors_last_24h` | Counter | >100 | Significant number of delivery failures |
| `error_rate` | Ratio | >10% | More than 1 in 10 attempts failing |
| `avg_delay` | Gauge | >300s | Average backoff is 5+ minutes |

### Secondary Metrics

| Metric | Type | Meaning |
|--------|------|---------|
| `inactive_rate_limits` | Gauge | MX domains with no issues (delay=0) |
| `whitelisted_count` | Gauge | Number of domains exempted from rate limiting |
| `event_volume` | Counter | Total rate limiting events (high = active monitoring) |
| `recovery_rate` | Ratio | % of rate limits that recovered (low = persistent issues) |

### Per-Domain Metrics

For critical MX domains, track individual metrics:

```
mx_rate_limit{mx_domain="gmail.com"}:delay_seconds
mx_rate_limit{mx_domain="outlook.com"}:error_count
mx_rate_limit{mx_domain="mail.example.com"}:success_count
```

## Monitoring Implementation

### 1. Prometheus Integration

Export metrics from your Postal instance to Prometheus:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'postal'
    static_configs:
      - targets: ['postal.example.com:5000']
    metrics_path: '/metrics'
    scrape_interval: 30s
```

### 2. API-Based Monitoring

Create a monitoring script that polls the MX rate limiting API every 5 minutes:

```bash
#!/bin/bash
# monitor-mx-rate-limiting.sh

set -e

POSTAL_API="https://postal.example.com/organizations/myorg/servers/myserver"
TOKEN="YOUR_API_TOKEN"
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Get current summary
SUMMARY=$(curl -s "$POSTAL_API/mx_rate_limits/summary" \
  -H "Authorization: Bearer $TOKEN")

ACTIVE=$(echo $SUMMARY | jq '.summary.active_rate_limits')
ERRORS=$(echo $SUMMARY | jq '.summary.errors_last_24h')
SUCCESSES=$(echo $SUMMARY | jq '.summary.successes_last_24h')

# Calculate error rate
if [ "$((ERRORS + SUCCESSES))" -gt 0 ]; then
  ERROR_RATE=$((100 * ERRORS / (ERRORS + SUCCESSES)))
else
  ERROR_RATE=0
fi

# Log metrics
echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) active_rate_limits=$ACTIVE errors_last_24h=$ERRORS error_rate=$ERROR_RATE"

# Alert if needed
if [ "$ACTIVE" -gt 10 ]; then
  curl -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    -d "{\"text\":\"⚠️ High rate limit activity: $ACTIVE domains throttled\"}"
fi
```

Run via cron every 5 minutes:
```
*/5 * * * * /usr/local/bin/monitor-mx-rate-limiting.sh
```

### 3. Database Monitoring

Query the database directly for real-time insights:

```sql
-- Active rate limits by server
SELECT 
  s.name as server,
  COUNT(*) as active_count,
  MAX(current_delay) as max_delay,
  AVG(current_delay) as avg_delay,
  SUM(error_count) as total_errors
FROM mx_rate_limits mrl
JOIN servers s ON mrl.server_id = s.id
WHERE mrl.current_delay > 0
GROUP BY s.id, s.name
ORDER BY active_count DESC;

-- Top problematic MX domains
SELECT 
  mx_domain,
  current_delay,
  error_count,
  success_count,
  last_error_at,
  last_error_message
FROM mx_rate_limits
WHERE server_id = 123
ORDER BY current_delay DESC
LIMIT 10;

-- Recent error events
SELECT 
  mle.created_at,
  mrl.mx_domain,
  mle.event_type,
  mle.smtp_response,
  mle.matched_pattern
FROM mx_rate_limit_events mle
JOIN mx_rate_limits mrl ON mle.mx_domain = mrl.mx_domain
WHERE mle.created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)
ORDER BY mle.created_at DESC
LIMIT 50;
```

## Alerting Rules

### High Priority (Immediate Action)

**Alert Name:** `HighMXRateLimitingActivity`
**Condition:** More than 20 active rate limits
**Action:** Page on-call engineer

```
ALERT HighMXRateLimitingActivity IF
  mx_rate_limits_active_count > 20
  FOR 5m
  ANNOTATIONS {
    summary = "{{ $value }} MX domains are rate limited",
    description = "Multiple mail servers are experiencing issues"
  }
```

**Alert Name:** `CriticalMXBackoff`
**Condition:** Maximum delay exceeds 2 hours
**Action:** Page on-call engineer

```
ALERT CriticalMXBackoff IF
  mx_rate_limits_max_delay_seconds > 7200
  FOR 5m
  ANNOTATIONS {
    summary = "MX servers backed off for {{ $value }}s",
    description = "Critical delivery issues - intervention may be required"
  }
```

### Medium Priority (Notifications)

**Alert Name:** `ElevatedMXErrors`
**Condition:** Error rate exceeds 10%
**Action:** Notify team channel

```
ALERT ElevatedMXErrors IF
  (mx_rate_limit_errors_last_24h / 
   (mx_rate_limit_errors_last_24h + mx_rate_limit_successes_last_24h))
  > 0.1
  FOR 30m
  ANNOTATIONS {
    summary = "Error rate is {{ $value | humanizePercentage }}",
    description = "Mail delivery error rate is above normal"
  }
```

**Alert Name:** `HighAvgDelay`
**Condition:** Average delay exceeds 5 minutes
**Action:** Notify team channel

```
ALERT HighAvgDelay IF
  mx_rate_limits_avg_delay_seconds > 300
  FOR 15m
  ANNOTATIONS {
    summary = "Average delay is {{ $value | humanizeDuration }}",
    description = "Rate limiting is affecting average delivery time"
  }
```

### Low Priority (Logging)

**Alert Name:** `MXRateLimitingActivity`
**Condition:** Any rate limiting events detected
**Action:** Log to central monitoring system

```
EVENT MXRateLimitingActivity IF
  mx_rate_limit_events_total > 100
  IN last 1h
  ACTIONS {
    log_to = "metrics_logger",
    tags = ["mx-rate-limiting", "delivery"]
  }
```

## Dashboard Setup

### Grafana Dashboard Example

```json
{
  "dashboard": {
    "title": "MX Rate Limiting",
    "panels": [
      {
        "title": "Active Rate Limits",
        "targets": [
          {
            "expr": "mx_rate_limits_active_count"
          }
        ],
        "type": "graph"
      },
      {
        "title": "Max Delay (Seconds)",
        "targets": [
          {
            "expr": "mx_rate_limits_max_delay_seconds"
          }
        ],
        "type": "graph"
      },
      {
        "title": "24h Error Rate",
        "targets": [
          {
            "expr": "rate(mx_rate_limit_errors_total[24h])"
          }
        ],
        "type": "gauge"
      },
      {
        "title": "Events Last 24h",
        "targets": [
          {
            "expr": "mx_rate_limit_events_total",
            "legendFormat": "{{ event_type }}"
          }
        ],
        "type": "table"
      },
      {
        "title": "Top 10 Problematic Domains",
        "targets": [
          {
            "expr": "topk(10, mx_rate_limits_active_count{mx_domain != \"\"})"
          }
        ],
        "type": "table"
      }
    ]
  }
}
```

### Key Dashboard Visualizations

1. **Timeline View** - Shows when rate limiting events occur
2. **Heat Map** - Maps delay severity across domains
3. **Error Distribution** - Pie chart of error types
4. **Recovery Trends** - Line graph of successful recoveries
5. **Domain Comparison** - Multi-series chart comparing top domains

## Log Analysis

### Important Log Patterns

**High-volume errors from specific domain:**
```bash
grep "mx_domain=mail.example.com" /var/log/postal/*.log | \
  grep "event_type=error" | wc -l
```

**Slow recovery:**
```bash
grep "event_type=delay_increased" /var/log/postal/*.log | \
  grep "mx_domain=slow.example.com" | tail -20
```

**Whitelisted domain activity:**
```bash
grep "whitelisted=true" /var/log/postal/*.log | \
  grep "mx_domain=important.com"
```

### Log Aggregation Setup (ELK Stack)

```yaml
# logstash.conf
filter {
  if [type] == "postal_mx_rate_limiting" {
    grok {
      match => { "message" => "%{TIMESTAMP_ISO8601:timestamp} %{WORD:event_type} mx_domain=%{WORD:mx_domain} delay=%{INT:delay}" }
    }
    mutate {
      convert => { "delay" => "integer" }
      add_tag => [ "mx_rate_limiting" ]
    }
  }
}

output {
  if "mx_rate_limiting" in [tags] {
    elasticsearch {
      hosts => ["elasticsearch:9200"]
      index => "postal-mx-rate-limiting-%{+YYYY.MM.dd}"
    }
  }
}
```

## Troubleshooting

### Issue: Constantly Escalating Delays

**Symptoms:**
- Delay keeps increasing despite successful deliveries
- Recovery threshold never reached

**Diagnosis:**
```bash
curl "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/mail.example.com/stats" \
  -H "Authorization: Bearer $TOKEN" | jq '.rate_limit'
```

**Solutions:**
1. Check if success_count is incrementing (may indicate threshold too high)
2. Lower `mx_rate_limiting_recovery_threshold` config
3. Check if domain is on whitelist (should bypass rate limiting)
4. Verify SMTP connection issues are resolved on recipient end

### Issue: Whitelisted Domains Still Throttled

**Diagnosis:**
```bash
# Check if domain is actually whitelisted
curl "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/whitelists" \
  -H "Authorization: Bearer $TOKEN" | jq '.whitelists[] | select(.mx_domain=="important.com")'
```

**Solutions:**
1. Verify whitelist pattern_type matches domain (exact vs prefix)
2. Check case-sensitivity (domains are normalized to lowercase)
3. Restart Postal worker if whitelist was recently added
4. Test with API endpoint to confirm whitelist is active

### Issue: False Positives (Good Servers Getting Throttled)

**Symptoms:**
- Reliable mail servers being rate limited
- Error count is low but delay still increasing

**Diagnosis:**
```bash
# Check error patterns
curl "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/mail.example.com/stats" \
  -H "Authorization: Bearer $TOKEN" | jq '.events_last_24h[] | select(.event_type=="error")'
```

**Solutions:**
1. Review matched_pattern to understand what's triggering errors
2. Adjust pattern configuration if too sensitive
3. Whitelist the domain if it's a trusted provider
4. Increase `mx_rate_limiting_recovery_threshold` to require more successes

### Issue: Rate Limiting Not Working

**Diagnosis:**
```bash
# Check if rate limiting is enabled
curl "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/summary" \
  -H "Authorization: Bearer $TOKEN"

# Should show active_rate_limits > 0 if working
```

**Solutions:**
1. Verify `mx_rate_limiting_enabled` is true in config
2. Check shadow_mode is false (shadow_mode logs without throttling)
3. Ensure patterns are loaded via database migration
4. Check worker logs for errors: `postal worker --log-level debug`

## Best Practices

1. **Review daily** - Check dashboard each morning for overnight issues
2. **Tune incrementally** - Change one config parameter at a time
3. **Whitelist strategically** - Only whitelist truly critical providers
4. **Archive old events** - Regularly purge events older than retention period
5. **Test patterns** - Validate new patterns before deploying
6. **Monitor recovery** - Track successful recovery rate as a health metric
7. **Scale alerts** - Start with high thresholds and gradually lower them
8. **Document decisions** - Record why domains are whitelisted

## Related Documentation

- [MX Rate Limiting Configuration](../MX_RATE_LIMITING_CONFIGURATION.md)
- [MX Rate Limiting API](./MX_RATE_LIMITING_API.md)
- [Postal Deployment Guide](../deployment/README.md)
- [Logging Configuration](../logging/README.md)
