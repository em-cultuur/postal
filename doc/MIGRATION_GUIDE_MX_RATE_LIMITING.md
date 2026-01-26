# MX Rate Limiting Migration Guide

This guide walks you through migrating an existing Postal installation to use MX rate limiting, including configuration, testing, and rollout strategies.

## Table of Contents

1. [Pre-Migration Checklist](#pre-migration-checklist)
2. [Installation Steps](#installation-steps)
3. [Configuration](#configuration)
4. [Testing & Validation](#testing--validation)
5. [Deployment Strategies](#deployment-strategies)
6. [Rollback Procedures](#rollback-procedures)
7. [Monitoring Post-Migration](#monitoring-post-migration)

## Pre-Migration Checklist

Before starting the migration, ensure:

- [ ] Current Postal version is 7.1.5.2 or later
- [ ] Database backups are current
- [ ] All Postal services are running
- [ ] You have administrative access to your Postal instance
- [ ] Maintenance window is scheduled (optional, feature is backward compatible)
- [ ] Team is trained on monitoring and alerting

## Installation Steps

### Step 1: Update Postal Code

```bash
# Pull latest code from your repository
git pull origin main

# Install any new dependencies
bundle install

# Check for new migrations
bundle exec rake db:pending_migrations
```

### Step 2: Run Database Migrations

```bash
# Run migrations in production
RAILS_ENV=production bundle exec rake db:migrate

# Verify migration completed successfully
RAILS_ENV=production bundle exec rake db:migrate:status | grep -A 5 "mx_rate_limit"
```

Expected output:
```
 up     20260123000001  Create mx rate limits
 up     20260123000002  Create mx rate limit patterns
 up     20260123000003  Create mx rate limit events
 up     20260126000006  Populate default mx rate limit patterns
 up     20260126000007  Add mx rate limit whitelist support
```

### Step 3: Verify Database Schema

```bash
# Check that tables were created
RAILS_ENV=production bundle exec rails dbconsole << EOF
SHOW TABLES LIKE 'mx_rate_limit%';
DESCRIBE mx_rate_limits;
DESCRIBE mx_rate_limit_events;
DESCRIBE mx_rate_limit_patterns;
DESCRIBE mx_rate_limit_whitelists;
EXIT
EOF
```

### Step 4: Reload Web and Worker Services

```bash
# Stop all services
supervisorctl stop postal:*

# Clear Rails cache
RAILS_ENV=production bundle exec rails cache:clear

# Start services again
supervisorctl start postal:*

# Verify services are running
supervisorctl status
```

## Configuration

### Step 1: Enable Feature (Default: Enabled)

The feature is enabled by default. To verify:

```bash
curl -H "Authorization: Bearer YOUR_API_TOKEN" \
  https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/summary
```

If you see a successful response, the feature is enabled.

### Step 2: Configure Rate Limiting Parameters

Edit your `config/postal/postal.yml`:

```yaml
postal:
  # Enable/disable the feature
  mx_rate_limiting_enabled: true
  
  # Start with shadow mode to observe without throttling
  mx_rate_limiting_shadow_mode: true  # Change to false after validation
  
  # Backoff configuration
  mx_rate_limiting_delay_increment: 300    # 5 minutes per error
  mx_rate_limiting_max_delay: 3600         # Cap at 60 minutes
  
  # Recovery configuration
  mx_rate_limiting_recovery_threshold: 5   # 5 successes needed
  mx_rate_limiting_delay_decrement: 120    # Reduce by 2 minutes per recovery
  
  # Caching and cleanup
  mx_rate_limiting_mx_cache_ttl: 3600      # 1 hour DNS cache
  mx_rate_limiting_cleanup_interval: 3600  # Run cleanup hourly
  
  # Data retention
  mx_rate_limiting_event_retention_days: 30
  mx_rate_limiting_inactive_cleanup_hours: 24
```

Or via environment variables:

```bash
export POSTAL_MX_RATE_LIMITING_ENABLED=true
export POSTAL_MX_RATE_LIMITING_SHADOW_MODE=true
export POSTAL_MX_RATE_LIMITING_DELAY_INCREMENT=300
export POSTAL_MX_RATE_LIMITING_MAX_DELAY=3600
export POSTAL_MX_RATE_LIMITING_RECOVERY_THRESHOLD=5
export POSTAL_MX_RATE_LIMITING_DELAY_DECREMENT=120
```

### Step 3: Restart Services with New Configuration

```bash
supervisorctl restart postal:*
```

## Testing & Validation

### Test 1: Verify Feature is Active

```bash
# Check for rate limit records
RAILS_ENV=production bundle exec rails dbconsole << EOF
SELECT COUNT(*) as rate_limit_count FROM mx_rate_limits;
SELECT COUNT(*) as pattern_count FROM mx_rate_limit_patterns;
EXIT
EOF
```

### Test 2: Check Default Patterns

```bash
RAILS_ENV=production bundle exec rails dbconsole << EOF
SELECT pattern_name, pattern FROM mx_rate_limit_patterns LIMIT 5;
EXIT
EOF
```

### Test 3: Validate via API

```bash
# List rate limits for a server
curl -H "Authorization: Bearer YOUR_API_TOKEN" \
  https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits | jq '.'

# Get summary statistics
curl -H "Authorization: Bearer YOUR_API_TOKEN" \
  https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits/summary | jq '.'
```

### Test 4: Run Test Suite

```bash
# Run MX rate limiting tests
bundle exec rspec spec/models/mx_rate_limit_spec.rb
bundle exec rspec spec/models/mx_rate_limit_whitelist_spec.rb
bundle exec rspec spec/controllers/mx_rate_limits_controller_spec.rb
```

Expected: All tests should pass.

### Test 5: Monitor in Shadow Mode

Shadow mode allows you to see what would be rate limited without actually throttling:

1. Keep `mx_rate_limiting_shadow_mode: true` for 24-48 hours
2. Monitor logs and events to understand patterns
3. Check dashboard for common issues
4. Review error patterns to validate configuration

```bash
# View recent events in shadow mode
curl -H "Authorization: Bearer YOUR_API_TOKEN" \
  https://postal.example.com/organizations/myorg/servers/myserver/mx_rate_limits | \
  jq '.rate_limits[] | select(.current_delay_seconds > 0)'
```

## Deployment Strategies

### Conservative Approach (Recommended)

For production systems, use a gradual rollout:

**Phase 1: Shadow Mode (Days 1-3)**
- Enable feature in shadow mode
- Monitor for unexpected behavior
- Validate patterns are not too aggressive
- Communicate status to support team

**Phase 2: Selective Servers (Days 4-7)**
- Enable rate limiting on non-critical servers first
- Monitor for issues
- Adjust configuration based on observations

**Phase 3: All Servers (Days 8+)**
- Roll out to all remaining servers
- Continue monitoring
- Keep support team on standby

**Phase 4: Optimization (Ongoing)**
- Fine-tune parameters based on statistics
- Add whitelists for known issues
- Update monitoring rules

### Fast Approach

For non-production or new installations:

1. Deploy code
2. Run migrations
3. Set configuration
4. Enable in production immediately
5. Monitor closely for first week

## Rollback Procedures

If you need to disable the feature:

### Quick Disable (Keep Data)

```bash
# Temporarily disable via config
POSTAL_MX_RATE_LIMITING_ENABLED=false supervisorctl restart postal:*
```

### Full Rollback (Remove Feature)

```bash
# If absolutely necessary, revert to previous migration state
RAILS_ENV=production bundle exec rake db:rollback STEP=1

# This will:
# - Drop mx_rate_limit_whitelists table
# - Remove whitelisted column from mx_rate_limits
# - Drop all MX rate limiting tables
# - Remove feature entirely

# Then restart services
supervisorctl restart postal:*
```

**Warning:** Full rollback will lose all rate limit history and configuration.

## Monitoring Post-Migration

### Immediate Actions (Day 1)

1. **Set up alerts** - Configure threshold alerts as per monitoring guide
2. **Create dashboard** - Import Grafana dashboard template
3. **Notify team** - Brief support on feature behavior
4. **Document URLs** - Share API endpoint documentation

### Daily Tasks (First Week)

- Review dashboard each morning
- Check for unexpectedlyrate limited domains
- Validate error patterns match known issues
- Adjust thresholds if needed
- Monitor event volume and trends

### Weekly Tasks

- Review statistics trends
- Analyze recovery patterns
- Update whitelists if needed
- Share metrics with team
- Plan configuration optimizations

### Monthly Tasks

- Archive old events (automatic via cleanup)
- Review overall system health
- Optimize patterns based on data
- Update documentation with learnings
- Plan feature enhancements

## Post-Migration Optimization

### Pattern Tuning

Review which patterns are triggering most often:

```sql
SELECT 
  matched_pattern,
  COUNT(*) as error_count,
  COUNT(DISTINCT mx_domain) as affected_domains
FROM mx_rate_limit_events
WHERE event_type = 'error'
  AND created_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY matched_pattern
ORDER BY error_count DESC;
```

Adjust patterns that are too sensitive or add new patterns for undetected issues.

### Configuration Tuning

Analyze recovery success rate:

```sql
SELECT
  (COUNT(CASE WHEN event_type = 'delay_decreased' THEN 1 END) * 100.0 /
   COUNT(CASE WHEN event_type = 'delay_increased' THEN 1 END)) as recovery_rate
FROM mx_rate_limit_events
WHERE created_at > DATE_SUB(NOW(), INTERVAL 7 DAY);
```

- **High recovery rate (>80%)** - Delay increment may be too aggressive, reduce threshold
- **Low recovery rate (<20%)** - Recovery threshold may be too high, increase successes needed

### Whitelisting Strategy

Identify domains that should never be rate limited:

```sql
SELECT 
  mx_domain,
  error_count,
  success_count,
  ROUND(100.0 * error_count / (error_count + success_count), 2) as error_rate
FROM mx_rate_limits
WHERE error_count + success_count > 1000
  AND current_delay > 0
ORDER BY error_count DESC;
```

Add critical providers to whitelist to prevent legitimate delivery issues.

## Troubleshooting

### Issue: No Rate Limit Events After Migration

**Cause:** Patterns may not be matching error responses
**Solution:**
1. Check `mx_rate_limit_patterns` table has rows
2. Review error messages in delivery logs
3. Verify pattern regex is correct
4. Test pattern in regex tester tool

### Issue: Too Many False Positives

**Cause:** Patterns too sensitive or configuration too aggressive
**Solution:**
1. Switch to shadow mode temporarily
2. Analyze matched patterns
3. Disable or modify overly-sensitive patterns
4. Increase recovery threshold

### Issue: Rate Limited Domains Not Recovering

**Cause:** Recovery threshold too high or success messages not matching
**Solution:**
1. Increase `delay_decrement` to reduce faster
2. Reduce `recovery_threshold` to require fewer successes
3. Verify successful delivery events are being recorded

## Success Criteria

Migration is successful when:

- [ ] All migrations run without error
- [ ] API endpoints respond with correct data
- [ ] Rate limiting events are recorded
- [ ] Dashboard displays metrics
- [ ] Alerts trigger appropriately
- [ ] No performance degradation observed
- [ ] Support team confirms expected behavior
- [ ] No customer complaints about delivery
- [ ] Recovery rate is >50%
- [ ] False positive rate is <5%

## Support & Documentation

For additional help:

1. **API Documentation** - See [MX Rate Limiting API](./api/MX_RATE_LIMITING_API.md)
2. **Configuration Guide** - See [MX Rate Limiting Configuration](./MX_RATE_LIMITING_CONFIGURATION.md)
3. **Monitoring Guide** - See [MX Rate Limiting Monitoring](./MX_RATE_LIMITING_MONITORING.md)
4. **GitHub Issues** - Report bugs or request features
5. **Community Slack** - Ask for help and share experiences

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-26 | Initial release |

---

**Last Updated:** 2026-01-26  
**Maintained By:** Postal Development Team
