# MySQL Configuration Recommendations for High-Concurrency Postal Deployments

## Problem Description

When running Postal with multiple workers and high thread counts (e.g., 8 workers × 10 threads = 80 concurrent threads), deadlocks can occur in the `queued_messages` table. These deadlocks manifest as:

```
ActiveRecord::Deadlocked: Mysql2::Error: Deadlock found when trying to get lock; try restarting transaction
```

Messages may show as "Sent" and then immediately transition to "Error" status.

## Root Causes

1. **Missing Indexes**: The `queued_messages` table lacked indexes for commonly used query patterns, causing MySQL to lock too many rows during updates
2. **Large Batch Updates**: Updating many messages at once for domain throttling and MX rate limiting created lock contention
3. **High Concurrency**: 80+ threads competing for locks on the same table increased deadlock probability

## Solutions Implemented

### 1. Database Indexes (Migration: 20260203100000)

Added four composite indexes to improve query performance and reduce lock contention:

```ruby
# For the main locking query in ProcessQueuedMessagesJob
index_queued_messages_on_lock_and_retry (locked_by, locked_at, retry_after, ip_address_id)

# For batch updates by domain
index_queued_messages_on_server_domain_retry (server_id, domain, retry_after)

# For batch updates by MX domain
index_queued_messages_on_server_mx_retry (server_id, mx_domain, retry_after)

# For batchable messages query
index_queued_messages_on_batch_lock (batch_key, ip_address_id, locked_by, locked_at)
```

### 2. Deadlock Retry Logic

Added automatic retry with exponential backoff in `MessageDequeuer`:

- Retries up to 3 times with increasing delays (0.1s, 0.2s, 0.4s)
- Includes random jitter to prevent synchronized retries
- Falls back to message requeuing after max retries

### 3. Batch Update Optimization

Modified batch update operations to:

- Process in smaller batches (100 messages at a time) instead of all at once
- Handle deadlocks gracefully without failing the entire operation
- Log partial completion for monitoring

### 4. Lock Timeout Configuration

Added shorter lock wait timeouts for batch message locking to fail fast instead of blocking.

## Recommended MySQL Configuration

For production environments with high concurrency, add these settings to your MySQL configuration:

```ini
# InnoDB settings for high concurrency
innodb_buffer_pool_size = 2G              # Increase based on available RAM
innodb_log_file_size = 512M               # Larger logs for better write performance
innodb_flush_log_at_trx_commit = 2        # Better performance, acceptable durability
innodb_flush_method = O_DIRECT            # Avoid double buffering

# Deadlock detection and handling
innodb_lock_wait_timeout = 5              # Default is 50s, reduce to fail faster
innodb_deadlock_detect = ON               # Enable automatic deadlock detection
innodb_print_all_deadlocks = ON           # Log deadlocks for monitoring

# Transaction and locking
transaction_isolation = READ-COMMITTED    # Reduce locking overhead (default is REPEATABLE-READ)
innodb_rollback_on_timeout = ON           # Rollback on lock timeout

# Connection and thread handling
max_connections = 200                     # Adjust based on worker count
thread_cache_size = 100                   # Reuse threads

# Query cache (if using MySQL < 8.0)
# query_cache_size = 0                    # Disable if on MySQL 8.0+
```

## Application Configuration Recommendations

### Worker Configuration

Instead of 8 workers × 10 threads (80 concurrent threads), consider:

**Option 1: More workers, fewer threads**
- 16 workers × 5 threads = 80 threads
- Better isolation, easier to scale horizontally

**Option 2: Reduce total concurrency**
- 8 workers × 8 threads = 64 threads
- Reduces contention while maintaining good throughput

**Option 3: Single-threaded workers (most reliable)**
- 40-80 workers × 1 thread each
- Eliminates most locking issues
- Easier to reason about resource usage

### Monitoring

Monitor these metrics to track improvement:

1. **Deadlock Rate**: Check MySQL error log for deadlock messages
   ```sql
   SHOW ENGINE INNODB STATUS;
   ```
   Look for "LATEST DETECTED DEADLOCK" section

2. **Lock Wait Time**: Track average lock wait time
   ```sql
   SELECT * FROM performance_schema.table_lock_waits_summary_by_table
   WHERE OBJECT_SCHEMA = 'postal' AND OBJECT_NAME = 'queued_messages';
   ```

3. **Message Processing Errors**: Monitor your logs for "Deadlock detected" warnings

## Migration Instructions

1. **Apply the database migration:**
   ```bash
   bundle exec rails db:migrate
   ```

2. **Update MySQL configuration** (if needed):
   - Edit `/etc/mysql/my.cnf` or `/etc/my.cnf`
   - Add recommended settings
   - Restart MySQL: `sudo systemctl restart mysql`

3. **Deploy the application changes:**
   - Deploy the updated code
   - Restart Postal workers

4. **Monitor for 24-48 hours:**
   - Check for reduced deadlock errors
   - Verify message processing is normal
   - Review MySQL slow query log

## Rollback Instructions

If issues occur after applying these changes:

1. **Rollback the migration:**
   ```bash
   bundle exec rails db:rollback
   ```

2. **Revert code changes:**
   ```bash
   git revert HEAD
   ```

3. **Restore original MySQL configuration** (if changed)

## Performance Impact

Expected improvements:
- ✅ Reduced deadlock errors (target: < 0.01% of messages)
- ✅ Faster query execution due to indexes
- ✅ More graceful degradation under high load

Potential trade-offs:
- ⚠️ Slightly increased memory usage for indexes (~5-10MB per million messages)
- ⚠️ Marginally slower INSERTs due to index maintenance (negligible in practice)

## Testing

Test in a staging environment before production:

1. **Load test with high concurrency:**
   ```ruby
   # Send a large batch of emails
   1000.times do |i|
     # Your email sending code
   end
   ```

2. **Monitor deadlock occurrence:**
   ```bash
   grep -i deadlock /var/log/mysql/error.log
   tail -f log/production.log | grep -i deadlock
   ```

3. **Verify throughput hasn't decreased:**
   - Compare message processing rate before/after
   - Check average delivery time

## Support

If deadlocks persist after applying these changes:

1. Check that indexes were created successfully:
   ```sql
   SHOW INDEX FROM queued_messages;
   ```

2. Verify MySQL configuration is applied:
   ```sql
   SHOW VARIABLES LIKE 'innodb_%';
   SHOW VARIABLES LIKE 'transaction_isolation';
   ```

3. Review the latest deadlock in MySQL:
   ```sql
   SHOW ENGINE INNODB STATUS\G
   ```

4. Consider further reducing worker thread count as a temporary measure.
