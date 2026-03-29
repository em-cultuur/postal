# Domain Throttling - SMTP Rate Limiting Management

## Overview

The Domain Throttling system automatically manages rate limiting when a destination SMTP server responds with a 451 "too many messages, slow down" error. Instead of immediately retrying the send (potentially causing further rejections and IP reputation damage), the system intelligently slows down sending for all messages destined for the same domain.

## Problem Solved

When sending a large volume of emails to a single domain, the destination server may respond with:

```
451 4.7.1 Too many messages, slow down
451 Rate limit exceeded, try again in 5 minutes
451 Too many connections from your IP
```

Without throttling management:
- ❌ Each message is retried individually
- ❌ Multiple retries worsen the situation
- ❌ Risk of IP blacklisting
- ❌ Resource waste

With Domain Throttling:
- ✅ Only one message receives the 451 error
- ✅ All messages for the same domain are delayed
- ✅ IP reputation is preserved
- ✅ Improved resource efficiency

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    OutgoingMessageProcessor                      │
│  ┌─────────────────────┐    ┌──────────────────────────────┐   │
│  │ skip_if_domain_     │    │ apply_domain_throttle_       │   │
│  │ throttled           │    │ if_required                  │   │
│  │ (before sending)    │    │ (after 451 error)            │   │
│  └──────────┬──────────┘    └──────────────┬───────────────┘   │
└─────────────┼───────────────────────────────┼───────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      DomainThrottle Model                        │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────────────┐   │
│  │ .throttled? │  │ .apply()   │  │ .cleanup_expired       │   │
│  └─────────────┘  └────────────┘  └────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Database: domain_throttles                    │
│  ┌──────────┬────────────┬─────────────────┬────────────────┐  │
│  │server_id │ domain     │ throttled_until │ reason         │  │
│  ├──────────┼────────────┼─────────────────┼────────────────┤  │
│  │ 1        │ gmail.com  │ 2025-12-10 13:00│ 451 too many...│  │
│  │ 1        │ yahoo.com  │ 2025-12-10 12:55│ Rate limit...  │  │
│  └──────────┴────────────┴─────────────────┴────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Execution Flow

```
1. Message in queue
        │
        ▼
2. Processor acquires lock
        │
        ▼
3. Check: domain throttled? ──YES──► Set retry_after, release lock
        │
        NO
        ▼
4. Proceed with SMTP send
        │
        ▼
5. Response from destination server
        │
   ┌────┴────┐
   │         │
 Success   451 Error
   │         │
   ▼         ▼
6. Done    Create DomainThrottle
           Update all queued_messages
           for the same domain
           Set retry_after
```

## Database Structure

### Table: domain_throttles

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Primary key |
| `server_id` | integer | FK to servers (per-server throttle) |
| `domain` | string | Destination domain (normalized lowercase) |
| `throttled_until` | datetime | Timestamp until the domain is throttled |
| `reason` | string | Original SMTP server error message |
| `created_at` | datetime | Creation timestamp |
| `updated_at` | datetime | Last update timestamp |

**Indexes:**
- `UNIQUE (server_id, domain)` - One throttle per domain per server
- `INDEX (throttled_until)` - For efficient cleanup queries

## Configuration

### Constants (DomainThrottle)

```ruby
# Default throttle duration (5 minutes)
DEFAULT_THROTTLE_DURATION = 300

# Maximum throttle duration (30 minutes)
MAX_THROTTLE_DURATION = 1800
```

### Detection Patterns

The system automatically detects the following patterns in SMTP errors:

- `451 ... too many` / `too many messages` / `too many connections`
- `rate limit` / `rate limited`
- `slow down`
- `temporarily deferred` / `temporarily rejected` with mention of rate/limit

### Duration Extraction

If the error message contains a specific time, it is extracted:

```
"Try again in 30 seconds" → 40 seconds (30 + 10 buffer)
"Retry in 5 minutes" → 310 seconds (5*60 + 10 buffer)
"Try again in 2 hours" → 1800 seconds (capped at MAX)
```

## DomainThrottle Model API

### Class Methods

```ruby
# Check if a domain is throttled
DomainThrottle.throttled?(server, "gmail.com")
# => DomainThrottle instance or nil

# Apply/extend a throttle
DomainThrottle.apply(
  server,
  "gmail.com",
  duration: 300,           # optional, default 300
  reason: "451 too many"   # optional
)
# => DomainThrottle instance

# Clean up expired throttles
DomainThrottle.cleanup_expired
# => number of deleted records
```

### Scopes

```ruby
# Active throttles
DomainThrottle.active

# Expired throttles
DomainThrottle.expired
```

### Instance Methods

```ruby
throttle.active?           # => true/false
throttle.remaining_seconds # => Integer (remaining seconds)
```

## Scheduled Task

The `PruneDomainThrottlesScheduledTask` task runs every **15 minutes** to remove expired throttle records from the database.

## Granularity

Throttling is applied **per-server**, which means that:

- If Server A receives a 451 from `gmail.com`, only Server A's messages to `gmail.com` are delayed
- Server B can continue sending to `gmail.com` normally
- This prevents an overloaded server from impacting other servers in the installation

## Batch Behavior

When a 451 error is detected:

1. The `DomainThrottle` for the domain is created/updated
2. **All** `queued_messages` from the same server with the same domain are updated in batch with `retry_after`
3. This prevents other workers from attempting to send while the domain is throttled

```ruby
# Batch update query
QueuedMessage.where(server_id: server_id, domain: domain)
             .where("retry_after IS NULL OR retry_after < ?", throttled_until)
             .update_all(retry_after: throttled_until + 10.seconds)
```

## Exponential Backoff

If a domain receives repeated 451 errors, the throttle duration increases progressively:

1. First 451: 5 minutes
2. Second 451 (while still throttled): remaining time × 2 (max 30 minutes)

This helps manage situations where the destination server needs more time to recover.

## Usage Examples

### Manual Status Check

```ruby
# In Rails console
server = Server.find(1)

# Check active throttles
server.domain_throttles.active

# Check if a specific domain is throttled
DomainThrottle.throttled?(server, "gmail.com")

# Manually remove a throttle
DomainThrottle.find_by(server: server, domain: "gmail.com")&.destroy
```

### Monitoring

```ruby
# Active throttle count per server
Server.all.each do |s|
  count = s.domain_throttles.active.count
  puts "#{s.name}: #{count} domains throttled" if count > 0
end

# Most frequently throttled domains
DomainThrottle.group(:domain)
              .order('count_id DESC')
              .count(:id)
              .first(10)
```

## Implemented Files

| File | Description |
|------|-------------|
| `db/migrate/20251210000001_create_domain_throttles.rb` | Database migration |
| `app/models/domain_throttle.rb` | ActiveRecord model |
| `app/models/server.rb` | Added `has_many :domain_throttles` association |
| `app/senders/send_result.rb` | New throttle attributes |
| `app/senders/smtp_sender.rb` | 451 error detection |
| `app/lib/message_dequeuer/outgoing_message_processor.rb` | Throttling logic |
| `app/scheduled_tasks/prune_domain_throttles_scheduled_task.rb` | Periodic cleanup |
| `app/controllers/messages_controller.rb` | UI actions (`throttled_domains`, `remove_throttled_domain`) |
| `app/views/messages/throttled_domains.html.haml` | Throttled domains list view |
| `app/views/messages/_header.html.haml` | Navigation menu link |
| `config/routes.rb` | Routes for the new pages |

## Web Interface

### Access

The "Throttled Domains" page is accessible from the **Messages** section of each server:

```
Organization → Server → Messages → Throttled Domains
```

### Features

The page shows a table with:

| Column | Description |
|--------|-------------|
| **Domain** | The destination domain being throttled |
| **Throttled Until** | Throttle expiration date and time |
| **Time Remaining** | Remaining time in human-readable format (e.g., "4m 30s") |
| **Reason** | The original SMTP server error message |
| **Actions** | Button to manually remove the throttle |

### Manual Removal

You can manually remove a throttle by clicking the "Remove" button. This is useful when:

- The problem on the remote server has been resolved
- You want to force a new send attempt
- The throttle was applied incorrectly

**Warning:** Removing a throttle will cause queued messages to be sent immediately. If the remote server is still rate limiting, this could result in additional 451 errors.

### Conceptual Screenshot

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Messages │ Outgoing │ Incoming │ Queue │ Held │ Send │ Suppressions │ [Throttled] │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Throttled Domains                                                          │
│                                                                             │
│  These domains are currently throttled due to rate limiting responses...   │
│                                                                             │
│  ┌────────────┬─────────────────────┬───────────┬──────────────┬─────────┐ │
│  │ Domain     │ Throttled Until     │ Remaining │ Reason       │ Actions │ │
│  ├────────────┼─────────────────────┼───────────┼──────────────┼─────────┤ │
│  │ gmail.com  │ Dec 10, 2025 14:30  │ 4m 30s    │ 451 too many │ Remove  │ │
│  │ yahoo.com  │ Dec 10, 2025 14:45  │ 19m 15s   │ Rate limit...│ Remove  │ │
│  └────────────┴─────────────────────┴───────────┴──────────────┴─────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Tests

Tests are available in:

- `spec/models/domain_throttle_spec.rb` - Model tests
- `spec/scheduled_tasks/prune_domain_throttles_scheduled_task_spec.rb` - Scheduled task tests
- `spec/senders/smtp_sender_spec.rb` - Throttle detection tests

Run the tests:

```bash
bundle exec rspec spec/models/domain_throttle_spec.rb \
                  spec/scheduled_tasks/prune_domain_throttles_scheduled_task_spec.rb \
                  spec/senders/smtp_sender_spec.rb
```

## Migration

To activate the feature:

```bash
bundle exec rails db:migrate
```

On Percona XtraDB Cluster, run the migration on a single node to avoid lock issues.
You need to temporarily run the following SQL command:
```sql
SET GLOBAL pxc_strict_mode=PERMISSIVE;
```

The feature is active immediately after migration, without any additional configuration needed.
