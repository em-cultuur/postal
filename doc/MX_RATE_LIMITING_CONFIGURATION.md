# MX Rate Limiting Configuration Guide

MX Rate Limiting is a security feature that automatically detects and responds to rate limiting responses from remote MX servers. This document explains all available configuration options.

## Overview

When a remote mail server responds with a rate limit error (such as 421, 450, etc.), Postal will:
1. **Record the error** and increment the error counter
2. **Apply exponential backoff** by delaying subsequent delivery attempts
3. **Recover gracefully** when the server is responding normally again
4. **Maintain metrics** about rate limiting events for monitoring

## Configuration Options

### `mx_rate_limiting_enabled`

**Type:** Boolean  
**Default:** `true`  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_ENABLED`

Enables or disables the entire MX rate limiting system. When disabled, rate limiting decisions are not applied.

```yaml
postal:
  mx_rate_limiting_enabled: true
```

### `mx_rate_limiting_shadow_mode`

**Type:** Boolean  
**Default:** `false`  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_SHADOW_MODE`

When enabled, the system logs rate limiting decisions and metrics WITHOUT actually applying delays to message delivery. Useful for testing and monitoring the rate limiting behavior before enforcing it in production.

```yaml
postal:
  mx_rate_limiting_shadow_mode: false
```

## Backoff Configuration

### `mx_rate_limiting_delay_increment`

**Type:** Integer (seconds)  
**Default:** `300` (5 minutes)  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_DELAY_INCREMENT`

The number of seconds to add to the delay for each consecutive error from the same MX server. This implements a linear backoff strategy.

**Example:** With a delay_increment of 300:
- 1st error: 300 seconds delay
- 2nd error: 600 seconds delay
- 3rd error: 900 seconds delay
- etc.

```yaml
postal:
  mx_rate_limiting_delay_increment: 300
```

### `mx_rate_limiting_max_delay`

**Type:** Integer (seconds)  
**Default:** `3600` (1 hour)  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_MAX_DELAY`

The maximum delay (cap) that can be applied to message delivery for a single MX server. Prevents the delay from growing indefinitely.

```yaml
postal:
  mx_rate_limiting_max_delay: 3600
```

## Recovery Configuration

### `mx_rate_limiting_recovery_threshold`

**Type:** Integer (count)  
**Default:** `5`  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_RECOVERY_THRESHOLD`

The number of consecutive successful deliveries required to trigger one recovery step (reducing the delay).

**Example:** With a recovery_threshold of 5:
- 5 successful deliveries → delay reduced by `delay_decrement`
- 10 successful deliveries → delay reduced again
- etc.

```yaml
postal:
  mx_rate_limiting_recovery_threshold: 5
```

### `mx_rate_limiting_delay_decrement`

**Type:** Integer (seconds)  
**Default:** `120` (2 minutes)  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_DELAY_DECREMENT`

The number of seconds to reduce the delay for each recovery step. When an MX server starts responding successfully, the delay is gradually reduced.

**Example:** With delay_decrement of 120:
- Current delay: 900 seconds → after recovery step → 780 seconds
- Current delay: 600 seconds → after recovery step → 480 seconds

```yaml
postal:
  mx_rate_limiting_delay_decrement: 120
```

## Monitoring & Cleanup Configuration

### `mx_rate_limiting_mx_cache_ttl`

**Type:** Integer (seconds)  
**Default:** `3600` (1 hour)  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_MX_CACHE_TTL`

Time-to-live for cached MX domain lookups. Postal caches DNS MX records to reduce DNS queries and improve performance.

```yaml
postal:
  mx_rate_limiting_mx_cache_ttl: 3600
```

### `mx_rate_limiting_cleanup_interval`

**Type:** Integer (seconds)  
**Default:** `3600` (1 hour)  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_CLEANUP_INTERVAL`

Interval for the background cleanup task that removes old events and inactive rate limit records.

```yaml
postal:
  mx_rate_limiting_cleanup_interval: 3600
```

### `mx_rate_limiting_event_retention_days`

**Type:** Integer (days)  
**Default:** `30`  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_EVENT_RETENTION_DAYS`

How long to retain MX rate limiting events in the database. Events older than this will be deleted during cleanup.

```yaml
postal:
  mx_rate_limiting_event_retention_days: 30
```

### `mx_rate_limiting_inactive_cleanup_hours`

**Type:** Integer (hours)  
**Default:** `24`  
**Environment Variable:** `POSTAL_MX_RATE_LIMITING_INACTIVE_CLEANUP_HOURS`

Hours after the last successful delivery to consider an MX rate limit record as inactive. Inactive records are cleaned up to save database space.

```yaml
postal:
  mx_rate_limiting_inactive_cleanup_hours: 24
```

## Configuration Examples

### Aggressive Rate Limiting (Quick Response)

For environments where you want to quickly respond to rate limits:

```yaml
postal:
  mx_rate_limiting_enabled: true
  mx_rate_limiting_shadow_mode: false
  mx_rate_limiting_delay_increment: 60        # Start with 1 minute delay
  mx_rate_limiting_max_delay: 600             # Cap at 10 minutes
  mx_rate_limiting_recovery_threshold: 3      # Recover after 3 successes
  mx_rate_limiting_delay_decrement: 30        # Reduce by 30 seconds per recovery
```

### Conservative Rate Limiting (Respect Server Limits)

For environments where you want to be very respectful to remote servers:

```yaml
postal:
  mx_rate_limiting_enabled: true
  mx_rate_limiting_shadow_mode: false
  mx_rate_limiting_delay_increment: 600       # Start with 10 minute delay
  mx_rate_limiting_max_delay: 7200            # Cap at 2 hours
  mx_rate_limiting_recovery_threshold: 10     # Recover after 10 successes
  mx_rate_limiting_delay_decrement: 60        # Reduce by 1 minute per recovery
```

### Testing/Development Mode

For testing the feature without enforcement:

```yaml
postal:
  mx_rate_limiting_enabled: true
  mx_rate_limiting_shadow_mode: true          # Log decisions but don't enforce
  mx_rate_limiting_delay_increment: 300
  mx_rate_limiting_max_delay: 3600
```

## Monitoring

Rate limiting events are stored in the `mx_rate_limit_events` table and can be queried through the API:

```bash
GET /org/{organization_id}/servers/{server_id}/mx_rate_limits
GET /org/{organization_id}/servers/{server_id}/mx_rate_limits/{mx_domain}/stats
GET /org/{organization_id}/servers/{server_id}/mx_rate_limits/summary
```

### API Response Example

```json
{
  "rate_limit": {
    "mx_domain": "gmail.com",
    "current_delay_seconds": 900,
    "error_count": 3,
    "success_count": 5,
    "last_error_at": "2024-01-26T12:00:00Z",
    "last_success_at": "2024-01-26T12:15:00Z",
    "last_error_message": "421"
  },
  "events_last_24h": [
    {
      "event_type": "error",
      "smtp_response": "421",
      "created_at": "2024-01-26T12:00:00Z"
    },
    {
      "event_type": "success",
      "created_at": "2024-01-26T12:15:00Z"
    }
  ]
}
```

## Security Considerations

1. **API Rate Limiting:** The MX rate limits API is rate limited to 60 requests per minute per IP address to prevent abuse.

2. **Domain Validation:** Only alphanumeric domains with dots and hyphens are allowed (format: `/^[a-zA-Z0-9.-]{1,255}$/`).

3. **Response Sanitization:** API responses only include SMTP response codes (e.g., "421"), not full error messages, to prevent infrastructure disclosure.

4. **Authorization:** Access to MX rate limits data requires proper organization and server access permissions.

## Troubleshooting

### High Delay Values

If you see very high delay values (approaching `max_delay`):
- The remote server may be experiencing sustained load
- Consider increasing `max_delay` to be more patient
- Check remote server status and logs
- Verify your sending IP reputation

### Messages Not Recovering

If messages are stuck with constant delays:
- Check the `recovery_threshold` - it may be too high
- Verify successful deliveries are being recorded
- Check if the remote server is still rate limiting
- Review logs for recent errors from that MX domain

### Database Growing Too Large

If the `mx_rate_limit_events` table is growing too large:
- Reduce `event_retention_days` to keep fewer events
- Verify the cleanup task is running (check logs)
- Consider running cleanup more frequently with a lower `cleanup_interval`

## Related Documentation

- [MX_RATE_LIMITING_SPECIFICATION.md](MX_RATE_LIMITING_SPECIFICATION.md) - Technical specification
- [AGENTS.md](AGENTS.md) - General configuration guidelines
