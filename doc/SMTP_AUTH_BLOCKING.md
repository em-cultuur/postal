# SMTP Authentication Failure Blocking

Postal includes a built-in system to protect against brute force attacks on SMTP authentication. This system automatically blocks IP addresses that exceed a threshold of failed authentication attempts.

## How It Works

When an IP address fails to authenticate via SMTP (using AUTH PLAIN, AUTH LOGIN, or AUTH CRAM-MD5), the system tracks the number of failures. Once the configured threshold is reached, that IP address is temporarily blocked from making further authentication attempts.

### Key Features

- **Automatic blocking**: IP addresses are automatically blocked after exceeding the failure threshold
- **Temporary blocks**: Blocks expire after a configurable duration
- **Cross-method tracking**: Failures are tracked across all authentication methods (PLAIN, LOGIN, CRAM-MD5)
- **Per-IP tracking**: Each IP address is tracked independently
- **Automatic reset**: The failure counter is reset upon successful authentication
- **Prometheus metrics**: Blocked IPs are tracked with Prometheus metrics for monitoring
- **Detailed logging**: All blocks and failures are logged for security auditing

## Configuration

The system can be configured using either environment variables or the YAML configuration file.

### Environment Variables

```bash
# Number of failed authentication attempts before blocking (default: 5)
SMTP_SERVER__AUTH_FAILURE_THRESHOLD=5

# Duration to block IP in minutes (default: 120 minutes = 2 hours)
SMTP_SERVER__AUTH_FAILURE_BLOCK_DURATION=120
```

### YAML Configuration

In your `postal.yml` file, under the `smtp_server` section:

```yaml
version: 2

smtp_server:
  # Number of failed authentication attempts before blocking (default: 5)
  auth_failure_threshold: 5
  
  # Duration to block IP in minutes (default: 120 minutes = 2 hours)
  auth_failure_block_duration: 120
```

## Default Values

If not configured, the system uses these defaults:

- **Threshold**: 5 failed attempts
- **Block Duration**: 120 minutes (2 hours)

## Examples

### Example 1: Strict Security (Low Threshold, Long Block)

Suitable for high-security environments where you want to be aggressive about blocking potential attackers:

```yaml
smtp_server:
  auth_failure_threshold: 3      # Block after 3 failures
  auth_failure_block_duration: 240  # Block for 4 hours
```

### Example 2: Lenient Configuration (High Threshold, Short Block)

Suitable for environments where legitimate users might occasionally mistype passwords:

```yaml
smtp_server:
  auth_failure_threshold: 10     # Block after 10 failures
  auth_failure_block_duration: 30   # Block for 30 minutes
```

### Example 3: Balanced Security (Recommended)

The default configuration provides a good balance:

```yaml
smtp_server:
  auth_failure_threshold: 5      # Block after 5 failures
  auth_failure_block_duration: 120  # Block for 2 hours
```

## SMTP Response Codes

When an IP is blocked, clients receive this response:

```
421 Too many authentication failures. Try again later.
```

The `421` code is a standard SMTP temporary failure code, indicating that the service is temporarily unavailable.

## Behavior Details

### Failure Tracking

- Failures are tracked across all authentication methods (PLAIN, LOGIN, CRAM-MD5)
- Each failed authentication attempt increments the counter for that IP address
- The counter is stored with an automatic expiry (default: 15 minutes window)
- If no more failures occur within the window, the counter naturally expires

### Successful Authentication

- A successful authentication immediately resets the failure counter to 0
- This prevents legitimate users from being blocked if they occasionally mistype a password

### Multiple Connections

- Blocks are per-IP address, not per-connection
- If an IP is blocked, all new connections from that IP will be rejected
- The block applies even if the client disconnects and reconnects

### Independent IP Tracking

- Each IP address is tracked completely independently
- Blocking one IP does not affect other IPs
- This prevents one attacker from causing collateral blocking

## Monitoring

### Prometheus Metrics

The system exports the following Prometheus metrics:

```
# Counter: Number of IP addresses blocked due to failed authentication
postal_smtp_server_auth_blocks_total

# Counter: Number of times blocked IPs attempted authentication
postal_smtp_server_client_errors{error="ip-blocked"}

# Counter: Failed authentication attempts (before blocking)
postal_smtp_server_client_errors{error="invalid-credentials"}
```

### Log Messages

The system logs important events:

**When a failure is recorded:**
```
Authentication failure for 192.168.1.100
```

**When an IP is blocked:**
```
IP 192.168.1.100 blocked after 5 failed authentication attempts
```

**When a blocked IP attempts authentication:**
```
Authentication blocked for 192.168.1.100 - too many failed attempts
```

## Security Considerations

### Cache Backend

The blocking system uses Rails.cache for storage. For production deployments:

- Ensure your cache backend (Memcached, Redis, etc.) is properly configured
- The cache should be persistent across server restarts if possible
- Consider cache memory limits to ensure space for blocking data

### Whitelisting

Currently, the system does not support IP whitelisting. If you need to whitelist certain IPs (e.g., monitoring systems), you can:

1. Use IP-based authentication (SMTP-IP credentials) instead
2. Modify the code to check against a whitelist before blocking

### Distributed Deployments

In distributed deployments with multiple SMTP servers:

- Each server tracks failures independently unless using a shared cache backend
- Use a shared cache backend (Redis, Memcached) to share block state across servers
- This ensures an attacker cannot bypass blocks by connecting to different servers

### Rate Limiting vs. Blocking

This system is designed for brute force protection, not rate limiting:

- **Brute force protection**: Blocks after X failures in a window
- **Rate limiting**: Limits number of attempts per time period

For rate limiting, consider using additional tools like fail2ban or iptables rate limiting.

## Troubleshooting

### Legitimate Users Are Being Blocked

If legitimate users are being blocked too frequently:

1. Increase the `auth_failure_threshold` value
2. Decrease the `auth_failure_block_duration` value
3. Check logs to identify why authentication is failing
4. Verify credentials are correct in client applications

### Blocks Are Not Working

If attackers are not being blocked:

1. Verify configuration is loaded correctly (check logs on startup)
2. Ensure Rails.cache is working properly
3. Check Prometheus metrics to see if blocks are being recorded
4. Verify the SMTP server process is reading the configuration

### Manual Unblocking

To manually unblock an IP address, you can use Rails console:

```ruby
# In Rails console
SMTPServer::AuthFailureTracker.unblock("192.168.1.100")
```

Or clear the entire cache (affects all blocks):

```ruby
Rails.cache.clear
```

## Implementation Details

### Files Modified/Created

- `app/lib/smtp_server/auth_failure_tracker.rb` - Main tracker class
- `app/lib/smtp_server/client.rb` - Modified to integrate blocking
- `lib/postal/config_schema.rb` - Added configuration options
- `spec/lib/smtp_server/auth_failure_tracker_spec.rb` - Unit tests
- `spec/lib/smtp_server/client/auth_blocking_spec.rb` - Integration tests

### Cache Keys

The system uses SHA-256 hashed cache keys for security:

- Failure counter: `smtp_auth:failures:v1:<sha256_of_ip>`
- Block status: `smtp_auth:blocked:v1:<sha256_of_ip>`

Hashing prevents cache key manipulation and normalizes key length.

## Future Enhancements

Possible future improvements:

- IP whitelist/blacklist configuration
- Progressive delays (increase delay with each failure)
- Permanent blocking after excessive failures
- Dashboard UI for viewing and managing blocked IPs
- Email notifications for security events
- Integration with external threat intelligence feeds

## References

- SMTP AUTH RFC: https://tools.ietf.org/html/rfc4954
- SMTP Response Codes: https://tools.ietf.org/html/rfc5321
