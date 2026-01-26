# MX Rate Limiting API

This document describes the API endpoints for managing and monitoring MX rate limiting in Postal.

## Overview

The MX Rate Limiting API provides endpoints to:
- Retrieve active rate limits for a mail server
- View detailed statistics for specific MX domains
- Access summary statistics across all rate limits
- Monitor recent events and historical trends

All endpoints require proper authentication and organization access.

## Base URL

```
/organizations/{organization_id}/servers/{server_id}/mx_rate_limits
```

## Authentication

All MX Rate Limiting endpoints require:
1. Valid user session or API token
2. Organization membership
3. Access to the specific server (admin or explicit server access)

## Endpoints

### 1. List Rate Limits

Retrieve all active and inactive rate limits for a server.

#### Request

```
GET /organizations/{organization_id}/servers/{server_id}/mx_rate_limits
Accept: application/json
```

#### Parameters

| Name | Type | Location | Required | Description |
|------|------|----------|----------|-------------|
| organization_id | string | path | yes | Organization identifier |
| server_id | string | path | yes | Server identifier |

#### Response

**Status: 200 OK**

```json
{
  "rate_limits": [
    {
      "mx_domain": "mail.example.com",
      "current_delay_seconds": 600,
      "error_count": 5,
      "success_count": 20,
      "last_error_at": "2024-01-26T10:30:00Z",
      "last_success_at": "2024-01-26T10:40:00Z",
      "last_error_message": "421",
      "created_at": "2024-01-20T08:00:00Z",
      "updated_at": "2024-01-26T10:40:00Z"
    },
    {
      "mx_domain": "mx.another.com",
      "current_delay_seconds": 0,
      "error_count": 0,
      "success_count": 45,
      "last_error_at": null,
      "last_success_at": "2024-01-26T10:50:00Z",
      "last_error_message": null,
      "created_at": "2024-01-22T12:00:00Z",
      "updated_at": "2024-01-26T10:50:00Z"
    }
  ]
}
```

#### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| mx_domain | string | The MX mail server domain |
| current_delay_seconds | integer | Current backoff delay in seconds (0-3600) |
| error_count | integer | Total delivery errors for this MX |
| success_count | integer | Total successful deliveries |
| last_error_at | datetime \| null | Timestamp of last error |
| last_success_at | datetime \| null | Timestamp of last success |
| last_error_message | string \| null | SMTP response code only (sanitized) |
| created_at | datetime | Rate limit record creation timestamp |
| updated_at | datetime | Rate limit record update timestamp |

#### Example

```bash
curl -X GET \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits" \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

### 2. Get Summary Statistics

Retrieve aggregated statistics for all rate limits on a server.

#### Request

```
GET /organizations/{organization_id}/servers/{server_id}/mx_rate_limits/summary
Accept: application/json
```

#### Parameters

| Name | Type | Location | Required | Description |
|------|------|----------|----------|-------------|
| organization_id | string | path | yes | Organization identifier |
| server_id | string | path | yes | Server identifier |

#### Response

**Status: 200 OK**

```json
{
  "summary": {
    "active_rate_limits": 3,
    "total_rate_limits": 45,
    "events_last_24h": 127,
    "errors_last_24h": 23,
    "successes_last_24h": 104
  }
}
```

#### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| active_rate_limits | integer | Number of MX domains with non-zero delay |
| total_rate_limits | integer | Total unique MX domains tracked |
| events_last_24h | integer | Total events in last 24 hours |
| errors_last_24h | integer | Total error events in last 24 hours |
| successes_last_24h | integer | Total success events in last 24 hours |

#### Example

```bash
curl -X GET \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/summary" \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

### 3. Get MX Domain Statistics

Retrieve detailed statistics for a specific MX domain, including recent events.

#### Request

```
GET /organizations/{organization_id}/servers/{server_id}/mx_rate_limits/{mx_domain}/stats
Accept: application/json
```

#### Parameters

| Name | Type | Location | Required | Description |
|------|------|----------|----------|-------------|
| organization_id | string | path | yes | Organization identifier |
| server_id | string | path | yes | Server identifier |
| mx_domain | string | path | yes | MX mail server domain (e.g., mail.example.com) |

#### Response

**Status: 200 OK**

```json
{
  "rate_limit": {
    "mx_domain": "mail.example.com",
    "current_delay_seconds": 600,
    "error_count": 5,
    "success_count": 20,
    "last_error_at": "2024-01-26T10:30:00Z",
    "last_success_at": "2024-01-26T10:40:00Z",
    "last_error_message": "421",
    "created_at": "2024-01-20T08:00:00Z",
    "updated_at": "2024-01-26T10:40:00Z"
  },
  "events_last_24h": [
    {
      "event_type": "error",
      "smtp_response": "421",
      "created_at": "2024-01-26T10:30:00Z"
    },
    {
      "event_type": "success",
      "smtp_response": null,
      "created_at": "2024-01-26T10:25:00Z"
    },
    {
      "event_type": "delay_increased",
      "smtp_response": null,
      "created_at": "2024-01-26T10:30:05Z"
    },
    {
      "event_type": "delay_decreased",
      "smtp_response": null,
      "created_at": "2024-01-26T10:40:10Z"
    }
  ]
}
```

#### Response Fields

**rate_limit object:**
| Field | Type | Description |
|-------|------|-------------|
| mx_domain | string | The MX mail server domain |
| current_delay_seconds | integer | Current backoff delay in seconds |
| error_count | integer | Total errors for this MX |
| success_count | integer | Total successes for this MX |
| last_error_at | datetime \| null | Last error timestamp |
| last_success_at | datetime \| null | Last success timestamp |
| last_error_message | string \| null | Last SMTP response code |
| created_at | datetime | Record creation timestamp |
| updated_at | datetime | Record update timestamp |

**Event object:**
| Field | Type | Description |
|-------|------|-------------|
| event_type | string | Event type: `error`, `success`, `delay_increased`, `delay_decreased` |
| smtp_response | string \| null | SMTP response code (only for errors) |
| created_at | datetime | Event timestamp |

#### Status Codes

| Code | Description |
|------|-------------|
| 200 | Success - rate limit found and statistics returned |
| 404 | Not Found - MX domain not in rate limit tracking |
| 422 | Invalid Request - domain format invalid (not matching [a-zA-Z0-9.-]{1,255}) |

#### Error Responses

**404 Not Found**
```json
{
  "error": "Not found"
}
```

**422 Unprocessable Entity**
```json
{
  "error": "Invalid request"
}
```

#### Example

```bash
curl -X GET \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/mail.example.com/stats" \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

## Event Types

The API returns events with the following types:

| Type | Description | When It Occurs |
|------|-------------|-----------------|
| `error` | Delivery attempt failed | SMTP connection failed, rejected, or timed out |
| `success` | Delivery attempt succeeded | Message accepted by MX |
| `delay_increased` | Backoff delay increased | Error occurred and delay was incremented |
| `delay_decreased` | Backoff delay decreased | Success threshold reached and delay was reduced |

---

## Rate Limiting

API endpoints are rate-limited to **60 requests per minute** per IP address using Rack::Attack.

**Rate Limit Headers:**
```
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 45
X-RateLimit-Reset: 1234567890
```

**When limit exceeded:**
```
HTTP/1.1 429 Too Many Requests
```

---

## Security Notes

### Response Sanitization

SMTP error messages are sanitized to prevent infrastructure disclosure:
- Only the SMTP response code (3 digits) is returned
- Full error details (hostname, version, etc.) are stripped
- Example: `421 Try again later` → `421`

### Authorization

- Users must be organization members
- Users must have access to the specified server:
  - Organization admins can access all servers
  - Regular users need explicit server access assignment
- Unauthorized requests return `404 Not Found` (not `403 Forbidden`) to prevent enumerating valid servers

### Input Validation

The `mx_domain` parameter is validated against `/^[a-zA-Z0-9.-]{1,255}$/`:
- Only allows alphanumeric characters, dots, and hyphens
- Maximum 255 characters
- Invalid domains return `422 Unprocessable Entity`

---

## Configuration

Rate limiting behavior can be configured via environment variables or config file:

| Setting | Env Variable | Default | Description |
|---------|--------------|---------|-------------|
| Enabled | `POSTAL_MX_RATE_LIMITING_ENABLED` | true | Enable/disable rate limiting |
| Shadow Mode | `POSTAL_MX_RATE_LIMITING_SHADOW_MODE` | false | Log without throttling |
| Delay Increment | `POSTAL_MX_RATE_LIMITING_DELAY_INCREMENT` | 300s | Backoff step size |
| Max Delay | `POSTAL_MX_RATE_LIMITING_MAX_DELAY` | 3600s | Maximum backoff cap |
| Recovery Threshold | `POSTAL_MX_RATE_LIMITING_RECOVERY_THRESHOLD` | 5 | Successes for recovery |
| Delay Decrement | `POSTAL_MX_RATE_LIMITING_DELAY_DECREMENT` | 120s | Recovery step size |

See [MX_RATE_LIMITING_CONFIGURATION.md](../MX_RATE_LIMITING_CONFIGURATION.md) for detailed configuration options.

---

## Examples

### Monitoring Dashboard

Get current overview of rate limits:

```bash
# Get summary
SUMMARY=$(curl -s \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/summary" \
  -H "Authorization: Bearer $TOKEN")

echo "Active rate limits: $(echo $SUMMARY | jq '.summary.active_rate_limits')"
echo "Errors (24h): $(echo $SUMMARY | jq '.summary.errors_last_24h')"
```

### Alert on High Error Rate

```bash
STATS=$(curl -s \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/mail.example.com/stats" \
  -H "Authorization: Bearer $TOKEN")

DELAY=$(echo $STATS | jq '.rate_limit.current_delay_seconds')
ERROR_COUNT=$(echo $STATS | jq '.rate_limit.error_count')

if [ "$DELAY" -gt 1800 ]; then
  echo "Alert: mail.example.com has delay >30 min"
fi
```

### Export Rate Limits

```bash
curl -s \
  "https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits" \
  -H "Authorization: Bearer $TOKEN" | jq '.rate_limits | sort_by(.current_delay_seconds) | reverse' > report.json
```

---

## Related Documentation

- [MX Rate Limiting Configuration](../MX_RATE_LIMITING_CONFIGURATION.md)
- [Postal API Documentation](./README.md)
- [Rate Limiting Overview](../MX_RATE_LIMITING_CONFIGURATION.md#overview)
