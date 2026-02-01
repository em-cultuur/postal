# SMTP Authentication Failure Blocking System

## Overview

This system protects the SMTP server against brute force authentication attacks by automatically blocking IP addresses that exceed a configurable number of failed authentication attempts.

## Features

- ✅ Automatic IP blocking after X failed authentication attempts
- ✅ Configurable threshold (default: 5 attempts)
- ✅ Configurable block duration (default: 120 minutes)
- ✅ Automatic failure counter reset on successful authentication
- ✅ Tracks failures across all authentication methods (PLAIN, LOGIN, CRAM-MD5)
- ✅ Per-IP tracking with independent counters
- ✅ Uses Rails.cache for fast, distributed storage
- ✅ Prometheus metrics for monitoring
- ✅ Detailed security logging
- ✅ Comprehensive test coverage

## Quick Start

### Configuration

Add to your `postal.yml`:

```yaml
version: 2

smtp_server:
  auth_failure_threshold: 5      # Block after 5 failures
  auth_failure_block_duration: 120  # Block for 120 minutes (2 hours)
```

Or use environment variables:

```bash
SMTP_SERVER__AUTH_FAILURE_THRESHOLD=5
SMTP_SERVER__AUTH_FAILURE_BLOCK_DURATION=120
```

### Monitoring

Check Prometheus metrics:

```
# Number of IPs blocked
postal_smtp_server_auth_blocks_total

# Number of blocked attempts
postal_smtp_server_client_errors{error="ip-blocked"}

# Failed authentication attempts
postal_smtp_server_client_errors{error="invalid-credentials"}
```

### Manual Unblocking

If you need to manually unblock an IP:

```ruby
# In Rails console
SMTPServer::AuthFailureTracker.unblock("192.168.1.100")
```

## How It Works

### 1. Failure Tracking

When a client fails to authenticate:

1. The IP address is extracted from the connection
2. A failure counter is incremented in Rails.cache
3. The counter has an automatic expiry (15-minute window)
4. If the threshold is reached, the IP is blocked

### 2. Blocking

When an IP exceeds the threshold:

1. A block record is created in Rails.cache
2. The block includes metadata (timestamp, failure count)
3. The block expires after the configured duration
4. All new authentication attempts from that IP are rejected

### 3. Success Reset

When authentication succeeds:

1. The failure counter is immediately reset to 0
2. This allows legitimate users to occasionally mistype passwords
3. The user can continue without being blocked

## Architecture

### Files

```
app/lib/smtp_server/
├── auth_failure_tracker.rb      # Core tracking logic
└── client.rb                     # Integration with SMTP client

lib/postal/
└── config_schema.rb              # Configuration schema

spec/lib/smtp_server/
├── auth_failure_tracker_spec.rb       # Unit tests
└── client/auth_blocking_spec.rb       # Integration tests

doc/
└── SMTP_AUTH_BLOCKING.md         # User documentation
```

### Key Classes

#### `SMTPServer::AuthFailureTracker`

Core tracking class that manages failure counters and blocks.

**Key Methods:**

- `blocked?` - Check if IP is currently blocked
- `record_failure_and_check_threshold` - Record failure and check if should block
- `record_success` - Reset counter on successful auth
- `block_ip` - Manually block an IP
- `unblock_ip` - Manually unblock an IP

**Class Methods:**

- `AuthFailureTracker.blocked?(ip)` - Check if IP is blocked
- `AuthFailureTracker.record_and_check(ip:, ...)` - Record and check
- `AuthFailureTracker.unblock(ip)` - Unblock an IP

#### `SMTPServer::Client`

SMTP client handler, modified to integrate blocking.

**Integration Points:**

- `initialize` - No longer pre-creates tracker (lazy load)
- `auth_failure_tracker` - Lazy-loading accessor for tracker
- `auth_plain`, `auth_login`, `auth_cram_md5` - Check if IP is blocked
- `authenticate` - Track failures and successes

### Cache Keys

The system uses SHA-256 hashed cache keys:

```
Failure counter: smtp_auth:failures:v1:<sha256_of_ip>
Block status:    smtp_auth:blocked:v1:<sha256_of_ip>
```

Hashing provides:
- Security against cache key manipulation
- Normalized key length regardless of IP format
- Version prefix allows future schema changes

### State Machine

```
┌─────────────┐
│   Normal    │  ← Successful auth resets counter
│ (unblocked) │
└──────┬──────┘
       │
       │ Failed auth attempt
       │
       ▼
┌─────────────┐
│  Tracking   │  ← Counter increments, not blocked yet
│  Failures   │     (counter < threshold)
└──────┬──────┘
       │
       │ Failure count >= threshold
       │
       ▼
┌─────────────┐
│   Blocked   │  ← All auth attempts rejected
│             │     421 response returned
└──────┬──────┘
       │
       │ Block expires (after configured duration)
       │
       ▼
┌─────────────┐
│   Normal    │  ← Counter cleared, can retry
└─────────────┘
```

## Testing

### Unit Tests

```bash
bundle exec rspec spec/lib/smtp_server/auth_failure_tracker_spec.rb
```

Tests the `AuthFailureTracker` class in isolation:
- Blocking/unblocking
- Counter management
- Configuration integration
- Cache key security

### Integration Tests

```bash
bundle exec rspec spec/lib/smtp_server/client/auth_blocking_spec.rb
```

Tests the full system integrated with SMTP client:
- AUTH PLAIN, LOGIN, CRAM-MD5 blocking
- Successful auth reset
- Cross-method failure tracking
- Independent IP tracking
- Logging and metrics

### Run All Tests

```bash
bundle exec rspec spec/lib/smtp_server/
```

## Security Considerations

### Cache Backend

- Uses Rails.cache for storage (memory, Redis, Memcached, etc.)
- Must be shared across SMTP servers in distributed deployments
- Configure appropriate memory limits
- Consider persistence across restarts

### Hashed Cache Keys

- IP addresses are SHA-256 hashed before use as cache keys
- Prevents cache key manipulation attacks
- Normalizes IPv4/IPv6 differences

### Rate vs. Blocking

This is a **blocking** system, not rate limiting:

| Feature | Blocking (This System) | Rate Limiting |
|---------|------------------------|---------------|
| Purpose | Stop brute force | Control request rate |
| Action | Binary (block/allow) | Throttle/delay |
| Recovery | Time-based expiry | Continuous |
| Best for | Security | Resource protection |

For additional rate limiting, consider:
- fail2ban at the network level
- iptables rate limiting rules
- Application-level rate limiting middleware

### Attack Scenarios

#### Scenario 1: Simple Brute Force

**Attack:** Single IP tries many passwords

**Protection:** ✅ Blocked after threshold attempts

#### Scenario 2: Distributed Brute Force

**Attack:** Many IPs each try a few passwords

**Protection:** ⚠️ Partially protected (each IP tracked independently)

**Mitigation:** 
- Lower threshold for stricter blocking
- Add account-level lockout (separate feature)
- Use external threat intelligence

#### Scenario 3: Credential Stuffing

**Attack:** Valid credentials from other breaches

**Protection:** ⚠️ Limited (may succeed before threshold)

**Mitigation:**
- Enable 2FA where possible
- Monitor for unusual patterns
- Integrate with breach databases

## Performance

### Memory Usage

Per-IP overhead:
- Failure counter: ~100 bytes
- Block record: ~200 bytes

Example: 10,000 IPs = ~3MB

### Cache Hits

- Check if blocked: 1 cache read
- Record failure: 1 cache read + 1 cache write
- Record success: 1 cache delete

All operations are O(1) with proper cache backend.

### Network Impact

With Redis/Memcached:
- ~50 bytes per operation
- Sub-millisecond latency

## Troubleshooting

### Problem: Legitimate users being blocked

**Symptoms:**
- Users report "Too many authentication failures"
- Metrics show many blocks

**Solutions:**
1. Increase `auth_failure_threshold`
2. Decrease `auth_failure_block_duration`
3. Check for misconfigured email clients
4. Verify credentials are correct

### Problem: Blocks not working

**Symptoms:**
- Attackers not being blocked
- No entries in logs
- Metrics not incrementing

**Diagnostics:**
1. Check Rails.cache is working: `Rails.cache.write("test", 1)`
2. Verify configuration is loaded: `Postal::Config.smtp_server.auth_failure_threshold`
3. Check logs for error messages
4. Verify SMTP server process restarted after config change

**Solutions:**
1. Ensure cache backend is properly configured
2. Check cache memory limits
3. Verify configuration file syntax
4. Restart SMTP server processes

### Problem: Blocks persist after expiry

**Symptoms:**
- IPs still blocked after configured duration
- `time_remaining_on_block` returns unexpected values

**Solutions:**
1. Check cache backend TTL handling
2. Manually unblock: `SMTPServer::AuthFailureTracker.unblock(ip)`
3. Clear entire cache: `Rails.cache.clear` (affects all cached data)

## Monitoring

### Key Metrics

Monitor these Prometheus metrics:

```promql
# Blocks per hour
rate(postal_smtp_server_auth_blocks_total[1h])

# Failed auth attempts
rate(postal_smtp_server_client_errors{error="invalid-credentials"}[5m])

# Blocked attempts
rate(postal_smtp_server_client_errors{error="ip-blocked"}[5m])
```

### Alerting Rules

Example Prometheus alerts:

```yaml
groups:
  - name: smtp_security
    rules:
      - alert: HighAuthFailureRate
        expr: rate(postal_smtp_server_client_errors{error="invalid-credentials"}[5m]) > 10
        for: 5m
        annotations:
          summary: High SMTP authentication failure rate

      - alert: ManyBlockedIPs
        expr: rate(postal_smtp_server_auth_blocks_total[1h]) > 5
        for: 10m
        annotations:
          summary: Many IP addresses being blocked
```

### Log Analysis

Key log patterns:

```
Authentication failure for <IP>
IP <IP> blocked after <N> failed authentication attempts
Authentication blocked for <IP> - too many failed attempts
```

Use these for:
- Security incident response
- Attack pattern analysis
- False positive identification

## Future Enhancements

Possible improvements:

- [ ] IP whitelist/blacklist configuration
- [ ] Progressive delays (exponential backoff)
- [ ] Permanent blocking after excessive attempts
- [ ] Dashboard UI for managing blocks
- [ ] Email notifications for security events
- [ ] Account-level lockout (independent of IP)
- [ ] Integration with external threat intelligence
- [ ] Geographic blocking rules
- [ ] Custom block reasons and messages
- [ ] API for managing blocks

## References

- [SMTP AUTH RFC 4954](https://tools.ietf.org/html/rfc4954)
- [SMTP Response Codes RFC 5321](https://tools.ietf.org/html/rfc5321)
- [User Documentation](../doc/SMTP_AUTH_BLOCKING.md)

## Support

For issues or questions:

1. Check the logs: `docker logs postal-smtp-1` or check your log files
2. Verify configuration: `Postal::Config.smtp_server.auth_failure_threshold`
3. Check metrics: View Prometheus dashboard
4. Review this README and user documentation
5. Check existing GitHub issues
6. Open a new issue with logs and configuration

## License

Part of the Postal mail server project.
