# MX-based Rate Limiting System - Technical Specification

## 📋 Document Information

- **Version:** 1.0.0
- **Date:** 2026-01-23
- **Status:** Draft - Ready for Review
- **Author:** AI Assistant
- **Target Release:** TBD

---

## 🎯 Executive Summary

This document specifies an intelligent, automatic rate limiting system for email delivery in Postal. The system monitors SMTP server responses, dynamically adjusts sending rates based on MX server behavior, and automatically recovers when conditions improve.

### Key Features

- **MX-level granularity**: Rate limiting per mail server (MX) rather than recipient domain
- **Automatic detection**: Pattern-based analysis of SMTP responses to detect rate limiting
- **Linear backoff**: Fixed delay increment on each consecutive error
- **Gradual recovery**: Progressive delay reduction based on successful deliveries
- **Fully automatic**: No manual configuration required
- **Comprehensive metrics**: Complete visibility into rate limiting status and effectiveness

### Design Principles

1. **Per-Server Isolation**: Each Postal server has independent rate limits
2. **MX-based Throttling**: Granularity based on actual mail server infrastructure
3. **Configurable Patterns**: SMTP response patterns stored in database
4. **Database-driven**: All state persisted in MySQL/MariaDB
5. **Backward Compatible**: Existing `DomainThrottle` system remains functional

---

## 🏗️ System Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Queue Message                                                │
│    - Resolve recipient domain → MX server (cached)              │
│    - Store mx_domain in queued_message                          │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Pre-Send Check (OutgoingMessageProcessor)                    │
│    - Check if mx_domain is rate limited                         │
│    - If YES: set retry_after and stop processing                │
│    - If NO: proceed with sending                                │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Send via SMTP (SMTPSender)                                   │
│    - Attempt delivery                                           │
│    - Capture SMTP response                                      │
└────────────────────┬────────────────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
┌──────────────────┐    ┌──────────────────────────────────────────┐
│ Success (250 OK) │    │ Error (4xx/5xx)                          │
└────────┬─────────┘    └────────┬─────────────────────────────────┘
         │                       │
         ▼                       ▼
┌──────────────────┐    ┌──────────────────────────────────────────┐
│ 4a. Record       │    │ 4b. Pattern Matching                     │
│     Success      │    │     - Match SMTP response against         │
│                  │    │       configured patterns                 │
│ - Increment      │    │     - Determine action (rate_limit,      │
│   success_count  │    │       hard_fail, soft_fail)              │
│ - Reset errors   │    └────────┬─────────────────────────────────┘
│ - Check recovery │             │
│   threshold      │             ▼
│                  │    ┌──────────────────────────────────────────┐
│ If threshold     │    │ 4c. Apply Rate Limit                     │
│ reached:         │    │     - Find/create MxRateLimit record     │
│ - Reduce delay   │    │     - Increment error_count              │
│                  │    │     - Increase current_delay (+5min)     │
└──────────────────┘    │     - Reset success_count                │
                        │     - Log event                          │
                        │     - Requeue all messages to MX         │
                        └──────────────────────────────────────────┘
```

### Integration Points

The MX rate limiting system integrates into the existing message processing pipeline:

**File:** `app/lib/message_dequeuer/outgoing_message_processor.rb`

**New processing steps:**
1. **resolve_mx_domain** (line ~13.5): Resolve and cache MX domain
2. **skip_if_mx_rate_limited** (line ~14): Check active rate limits before sending
3. **handle_mx_rate_limit_response** (line ~22.5): Process SMTP response after sending

**Existing steps maintained:**
- `skip_if_domain_throttled` - Keep old DomainThrottle for backward compatibility
- `apply_domain_throttle_if_required` - Continue using old system in parallel

---

## 📊 Database Schema

### 1. Table: `mx_rate_limits`

Primary table storing rate limiting state per MX server.

```sql
CREATE TABLE mx_rate_limits (
  id INT(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  server_id INT(11) NOT NULL,
  mx_domain VARCHAR(255) NOT NULL,
  current_delay INT(11) DEFAULT 0,
  error_count INT(11) DEFAULT 0,
  success_count INT(11) DEFAULT 0,
  last_error_at DATETIME,
  last_success_at DATETIME,
  last_error_message VARCHAR(255),
  max_attempts INT(11) DEFAULT 10,
  created_at DATETIME,
  updated_at DATETIME,
  
  UNIQUE INDEX index_mx_rate_limits_on_server_and_mx (server_id, mx_domain),
  INDEX index_mx_rate_limits_on_current_delay (current_delay),
  INDEX index_mx_rate_limits_on_last_error_at (last_error_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Field Descriptions:**

| Field | Type | Description |
|-------|------|-------------|
| `server_id` | INT | Foreign key to servers table |
| `mx_domain` | VARCHAR(255) | Main MX domain (e.g., "google.com" for Gmail MX servers) |
| `current_delay` | INT | Current delay in seconds between sends (0 = no throttling) |
| `error_count` | INT | Consecutive errors since last success |
| `success_count` | INT | Consecutive successes since last error |
| `last_error_at` | DATETIME | Timestamp of last error |
| `last_success_at` | DATETIME | Timestamp of last success |
| `last_error_message` | VARCHAR(255) | Last SMTP error message (truncated) |
| `max_attempts` | INT | Maximum retry attempts before hard fail |

**Indexes:**
- Unique composite index on `(server_id, mx_domain)` - ensures one rate limit per server+MX pair
- Index on `current_delay` - for finding active rate limits
- Index on `last_error_at` - for cleanup queries

### 2. Table: `mx_rate_limit_patterns`

Configurable patterns for detecting rate limiting in SMTP responses.

```sql
CREATE TABLE mx_rate_limit_patterns (
  id INT(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  pattern TEXT NOT NULL,
  enabled TINYINT(1) DEFAULT 1,
  priority INT(11) DEFAULT 0,
  action VARCHAR(255),
  suggested_delay INT(11),
  created_at DATETIME,
  updated_at DATETIME,
  
  INDEX index_mx_rate_limit_patterns_on_enabled (enabled),
  INDEX index_mx_rate_limit_patterns_on_priority (priority)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Field Descriptions:**

| Field | Type | Description |
|-------|------|-------------|
| `name` | VARCHAR(255) | Human-readable pattern name |
| `pattern` | TEXT | Regular expression pattern (case-insensitive) |
| `enabled` | BOOLEAN | Whether pattern is active |
| `priority` | INT | Match priority (higher = checked first) |
| `action` | VARCHAR(255) | Action to take: "rate_limit", "hard_fail", "soft_fail" |
| `suggested_delay` | INT | Optional suggested delay in seconds |

**Default Patterns:**

```ruby
[
  {
    name: "SMTP 421 Rate Limit",
    pattern: '\b421\b.*\b(rate limit|too many)\b',
    action: "rate_limit",
    priority: 100,
    suggested_delay: 300
  },
  {
    name: "SMTP 450 Rate Limit",
    pattern: '\b450\b.*\b(rate limit|too many)\b',
    action: "rate_limit",
    priority: 90,
    suggested_delay: 300
  },
  {
    name: "SMTP 451 Temporary",
    pattern: '\b451\b.*\b(try again|slow down|temporarily deferred)\b',
    action: "rate_limit",
    priority: 80,
    suggested_delay: 300
  },
  {
    name: "Too Many Messages",
    pattern: '\b(too many messages|too many connections|sending rate)\b',
    action: "rate_limit",
    priority: 70,
    suggested_delay: 300
  },
  {
    name: "Temporarily Rejected",
    pattern: '\b(temporarily rejected|temporarily deferred)\b.*\b(rate|limit)\b',
    action: "rate_limit",
    priority: 60,
    suggested_delay: 300
  },
  {
    name: "Permanent Block",
    pattern: '\b5[0-9]{2}\b.*\b(blocked|blacklisted|banned)\b',
    action: "hard_fail",
    priority: 50
  }
]
```

### 3. Table: `mx_rate_limit_events`

Event log for metrics, monitoring, and debugging.

```sql
CREATE TABLE mx_rate_limit_events (
  id INT(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  server_id INT(11) NOT NULL,
  mx_domain VARCHAR(255) NOT NULL,
  recipient_domain VARCHAR(255),
  event_type VARCHAR(255) NOT NULL,
  delay_before INT(11),
  delay_after INT(11),
  error_count INT(11),
  success_count INT(11),
  smtp_response TEXT,
  matched_pattern VARCHAR(255),
  queued_message_id INT(11),
  created_at DATETIME,
  
  INDEX index_mx_rate_limit_events_on_server_and_mx (server_id, mx_domain),
  INDEX index_mx_rate_limit_events_on_event_type (event_type),
  INDEX index_mx_rate_limit_events_on_created_at (created_at),
  INDEX index_mx_rate_limit_events_on_queued_message_id (queued_message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Event Types:**
- `error` - SMTP error received, rate limit applied
- `success` - Successful delivery
- `delay_increased` - Delay incremented due to error
- `delay_decreased` - Delay decremented due to recovery
- `throttled` - Message skipped due to active rate limit

**Retention:** Events older than 30 days are automatically deleted.

### 4. Table: `mx_domain_cache`

DNS MX resolution cache to avoid repeated lookups.

```sql
CREATE TABLE mx_domain_cache (
  id INT(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  recipient_domain VARCHAR(255) NOT NULL,
  mx_domain VARCHAR(255) NOT NULL,
  mx_records TEXT,
  resolved_at DATETIME NOT NULL,
  expires_at DATETIME NOT NULL,
  created_at DATETIME,
  updated_at DATETIME,
  
  UNIQUE INDEX index_mx_domain_cache_on_recipient_domain (recipient_domain),
  INDEX index_mx_domain_cache_on_expires_at (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Field Descriptions:**

| Field | Type | Description |
|-------|------|-------------|
| `recipient_domain` | VARCHAR(255) | Recipient email domain (e.g., "gmail.com") |
| `mx_domain` | VARCHAR(255) | Resolved main MX domain (e.g., "google.com") |
| `mx_records` | TEXT | Optional: JSON array of all MX records |
| `resolved_at` | DATETIME | When DNS resolution occurred |
| `expires_at` | DATETIME | Cache expiry (default: 1 hour after resolved_at) |

### 5. Modification to Existing Table: `queued_messages`

Add MX domain caching column.

```sql
ALTER TABLE queued_messages ADD COLUMN mx_domain VARCHAR(255);
ALTER TABLE queued_messages ADD INDEX index_queued_messages_on_mx_domain (mx_domain);
```

**Purpose:** Cache resolved MX domain to avoid repeated DNS lookups during message processing.

---

## 🔧 Core Components

### 1. Model: `MxRateLimit`

**File:** `app/models/mx_rate_limit.rb`

**Responsibilities:**
- Store and manage rate limiting state per MX domain
- Implement linear backoff on errors
- Implement gradual recovery on successes
- Track error/success counts
- Log events for metrics

**Key Constants:**

```ruby
DELAY_INCREMENT = 300              # +5 minutes per error
MAX_DELAY = 3600                   # Max 60 minutes delay
RECOVERY_SUCCESS_THRESHOLD = 5     # Successes needed to reduce delay
DELAY_DECREMENT = 120              # -2 minutes per recovery step
```

**Key Methods:**

```ruby
# Class methods
.rate_limited?(server, mx_domain) # Check if MX is currently throttled
.cleanup_inactive                 # Remove old inactive records

# Instance methods
#record_error(smtp_response:, pattern:, queued_message:)
  # - Increment error_count
  # - Reset success_count
  # - Increase current_delay by DELAY_INCREMENT (capped at MAX_DELAY)
  # - Log event
  
#record_success(queued_message:)
  # - Increment success_count
  # - Reset error_count
  # - If success_count >= RECOVERY_SUCCESS_THRESHOLD:
  #     - Decrease current_delay by DELAY_DECREMENT (min 0)
  #     - Reset success_count
  # - Log event

#active?                           # current_delay > 0
#wait_seconds                      # Returns current_delay
```

**Associations:**
- `belongs_to :server`
- `has_many :events, class_name: "MxRateLimitEvent"`

**Validations:**
- `mx_domain` presence and uniqueness (scoped to server_id)
- `current_delay` >= 0

### 2. Model: `MxRateLimitPattern`

**File:** `app/models/mx_rate_limit_pattern.rb`

**Responsibilities:**
- Store configurable SMTP response patterns
- Match patterns against SMTP error messages
- Determine appropriate action (rate_limit, hard_fail, soft_fail)

**Key Methods:**

```ruby
# Class methods
.match_message(smtp_message)      # Find first matching pattern (by priority)
.create_defaults!                  # Create default patterns

# Instance methods
#match?(smtp_message)              # Test if pattern matches message
```

**Scopes:**
- `enabled` - Only active patterns
- `ordered` - Sorted by priority DESC (highest first)

**Validations:**
- `name` and `pattern` presence
- `action` inclusion in ["rate_limit", "hard_fail", "soft_fail"]

### 3. Model: `MxRateLimitEvent`

**File:** `app/models/mx_rate_limit_event.rb`

**Responsibilities:**
- Log rate limiting events for metrics and debugging
- Provide statistics aggregation
- Auto-cleanup old events

**Key Methods:**

```ruby
# Class methods
.stats_for_mx(server, mx_domain, since: 24.hours.ago)
  # Returns hash of event_type => count
  
.cleanup_old                       # Delete events > 30 days old
```

**Associations:**
- `belongs_to :server`
- `belongs_to :queued_message, optional: true`

**Scopes:**
- `errors` - Error events only
- `successes` - Success events only
- `recent` - Last 24 hours

### 4. Model: `MxDomainCache`

**File:** `app/models/mx_domain_cache.rb`

**Responsibilities:**
- Cache DNS MX resolutions
- Auto-expire after TTL (default 1 hour)

**Key Methods:**

```ruby
# Class methods
.resolve(recipient_domain)         # Get cached or resolve MX domain
.cleanup_expired                   # Delete expired cache entries

# Instance methods
#expired?                          # expires_at < Time.current
```

**Scopes:**
- `expired` - Cache entries past expiry

**Validations:**
- `recipient_domain` and `mx_domain` presence
- `recipient_domain` uniqueness

### 5. Service: `MxDomainResolver`

**File:** `app/services/mx_domain_resolver.rb`

**Responsibilities:**
- Resolve recipient domain to MX server domain
- Cache results in `mx_domain_cache` table
- Extract main domain from MX hostname

**Algorithm:**

```
1. Check cache for recipient_domain
2. If cached AND not expired:
     Return cached mx_domain
3. Else:
     a. Resolve MX records via DNS (Resolv::DNS)
     b. Get primary MX (lowest preference number)
     c. Extract main domain from MX hostname
        Example: "gmail-smtp-in.l.google.com" → "google.com"
     d. Save to cache with 1-hour TTL
     e. Return mx_domain
4. On error:
     Log error and return recipient_domain as fallback
```

**Key Methods:**

```ruby
.resolve(recipient_domain)         # Main entry point
#resolve_mx_domain                 # Perform DNS lookup
#extract_main_domain(mx_hostname)  # Extract base domain
#cache_mx_domain(mx_domain)        # Save to cache
```

**Dependencies:**
- `resolv` (Ruby stdlib for DNS resolution)

**Future Enhancement:**
- Consider using `public_suffix` gem for more accurate domain extraction
- Support for IP-based MX records

### 6. Modified: `QueuedMessage` Model

**File:** `app/models/queued_message.rb`

**New Methods:**

```ruby
# Resolve and cache MX domain for this message
def resolve_mx_domain!
  return mx_domain if mx_domain.present?
  
  recipient_domain = message.recipient_domain
  return nil unless recipient_domain

  resolved = MxDomainResolver.resolve(recipient_domain)
  update_column(:mx_domain, resolved)
  resolved
end

# Check if MX is currently rate limited
def mx_rate_limited?
  return false unless mx_domain.present?
  MxRateLimit.rate_limited?(server, mx_domain)
end

# Get active rate limit for this message's MX
def mx_rate_limit
  return nil unless mx_domain.present?
  MxRateLimit.find_by(server: server, mx_domain: mx_domain)
end
```

### 7. Modified: `OutgoingMessageProcessor`

**File:** `app/lib/message_dequeuer/outgoing_message_processor.rb`

**New Processing Steps:**

#### Step: `resolve_mx_domain`

Position: After `check_rcpt_to`, before `skip_if_domain_throttled`

```ruby
def resolve_mx_domain
  queued_message.resolve_mx_domain!
  log "resolved MX domain", mx_domain: queued_message.mx_domain
rescue StandardError => e
  log "failed to resolve MX domain", error: e.message
  # Don't block processing if resolution fails
end
```

#### Step: `skip_if_mx_rate_limited`

Position: After `resolve_mx_domain`, before `skip_if_domain_throttled`

```ruby
def skip_if_mx_rate_limited
  return if queued_message.manual?
  return unless queued_message.mx_domain.present?

  rate_limit = queued_message.mx_rate_limit
  return unless rate_limit&.active?

  # Calculate retry time based on current delay
  retry_seconds = rate_limit.wait_seconds + 10
  queued_message.retry_later(retry_seconds)
  
  log "MX domain #{queued_message.mx_domain} is rate limited, requeuing",
      mx_domain: queued_message.mx_domain,
      current_delay: rate_limit.current_delay,
      error_count: rate_limit.error_count,
      retry_after: queued_message.retry_after
  
  # Log throttled event
  rate_limit.events.create!(
    server_id: queued_message.server_id,
    recipient_domain: queued_message.domain,
    event_type: "throttled",
    delay_before: rate_limit.current_delay,
    delay_after: rate_limit.current_delay,
    error_count: rate_limit.error_count,
    success_count: rate_limit.success_count,
    queued_message_id: queued_message.id
  )
  
  stop_processing
end
```

#### Step: `handle_mx_rate_limit_response`

Position: After `send_message_to_sender`, before `apply_domain_throttle_if_required`

```ruby
def handle_mx_rate_limit_response
  return unless @result
  return unless queued_message.mx_domain.present?

  # Analyze SMTP response
  if should_apply_mx_rate_limit?(@result)
    apply_mx_rate_limit
  elsif @result.type == "Sent"
    record_mx_success
  end
end

private

def should_apply_mx_rate_limit?(result)
  return false if result.type == "Sent"
  return false if result.output.blank?

  # Check pattern matching
  pattern = MxRateLimitPattern.match_message(result.output)
  return false unless pattern
  
  # Save matched pattern for logging
  @matched_pattern = pattern
  
  pattern.action == "rate_limit"
end

def apply_mx_rate_limit
  rate_limit = MxRateLimit.find_or_initialize_by(
    server: queued_message.server,
    mx_domain: queued_message.mx_domain
  )

  rate_limit.record_error(
    smtp_response: @result.output,
    pattern: @matched_pattern&.name,
    queued_message: queued_message
  )

  log "applied MX rate limit",
      mx_domain: queued_message.mx_domain,
      error_count: rate_limit.error_count,
      current_delay: rate_limit.current_delay,
      matched_pattern: @matched_pattern&.name

  # Requeue pending messages for same MX
  requeue_messages_for_mx(queued_message.mx_domain, rate_limit.current_delay)
end

def record_mx_success
  rate_limit = MxRateLimit.find_by(
    server: queued_message.server,
    mx_domain: queued_message.mx_domain
  )
  
  return unless rate_limit

  rate_limit.record_success(queued_message: queued_message)

  if rate_limit.current_delay == 0
    log "MX rate limit cleared",
        mx_domain: queued_message.mx_domain,
        success_count: rate_limit.success_count
  end
end

def requeue_messages_for_mx(mx_domain, delay_seconds)
  retry_after = Time.current + delay_seconds.seconds + 10.seconds

  # Update all queued messages for this MX domain
  updated_count = QueuedMessage
    .where(server_id: queued_message.server_id, mx_domain: mx_domain)
    .where("retry_after IS NULL OR retry_after < ?", retry_after)
    .where.not(id: queued_message.id)
    .update_all(retry_after: retry_after)

  if updated_count > 0
    log "requeued messages for MX domain",
        mx_domain: mx_domain,
        count: updated_count,
        retry_after: retry_after
  end
end
```

---

## 📈 Metrics and Monitoring

### API Endpoints

#### 1. List Active Rate Limits

```
GET /api/v1/servers/:server_id/mx_rate_limits
```

**Response:**
```json
[
  {
    "mx_domain": "google.com",
    "current_delay": 600,
    "error_count": 2,
    "success_count": 0,
    "last_error_at": "2026-01-23T10:30:00Z",
    "last_success_at": "2026-01-23T09:15:00Z",
    "last_error_message": "421 4.7.0 Try again later",
    "queued_messages_count": 47
  }
]
```

#### 2. MX Domain Statistics

```
GET /api/v1/servers/:server_id/mx_rate_limits/:mx_domain/stats
```

**Response:**
```json
{
  "events_24h": {
    "error": 5,
    "success": 23,
    "throttled": 12
  },
  "events_7d": {
    "error": 18,
    "success": 542,
    "delay_increased": 6,
    "delay_decreased": 3
  },
  "queued_count": 47,
  "current_rate_limit": {
    "current_delay": 600,
    "error_count": 2
  }
}
```

#### 3. Global Summary

```
GET /api/v1/servers/:server_id/mx_rate_limits/summary
```

**Response:**
```json
{
  "active_rate_limits_count": 3,
  "total_rate_limits_count": 15,
  "queued_messages_delayed": 89,
  "events_last_24h": {
    "error": 12,
    "success": 456,
    "throttled": 34
  }
}
```

### Scheduled Cleanup Task

**File:** `app/scheduled_tasks/cleanup_mx_rate_limit_data_task.rb`

**Schedule:** Every 1 hour (configurable)

**Actions:**
1. Delete inactive rate limits (delay=0, last_success > 24h ago)
2. Delete old events (created > 30 days ago)
3. Delete expired MX domain cache entries

**Configuration:**
```yaml
# config/postal/postal.yml
scheduled_tasks:
  cleanup_mx_rate_limit_data:
    enabled: true
    interval: 3600  # seconds
```

---

## ⚙️ Configuration

### Configuration Schema

**File:** `lib/postal/config/config_schema.rb`

Add to `:postal` section:

```ruby
mx_rate_limiting: {
  type: :hash,
  default: {},
  schema: {
    enabled: { type: :boolean, default: true },
    shadow_mode: { type: :boolean, default: false },
    delay_increment: { type: :integer, default: 300 },
    max_delay: { type: :integer, default: 3600 },
    recovery_threshold: { type: :integer, default: 5 },
    delay_decrement: { type: :integer, default: 120 },
    mx_cache_ttl: { type: :integer, default: 3600 },
    cleanup_interval: { type: :integer, default: 3600 }
  }
}
```

### Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enabled` | Boolean | `true` | Enable MX rate limiting system |
| `shadow_mode` | Boolean | `false` | Log only, don't actually throttle messages |
| `delay_increment` | Integer | `300` | Seconds to add per error (5 minutes) |
| `max_delay` | Integer | `3600` | Maximum delay in seconds (60 minutes) |
| `recovery_threshold` | Integer | `5` | Successes needed for one recovery step |
| `delay_decrement` | Integer | `120` | Seconds to reduce per recovery (2 minutes) |
| `mx_cache_ttl` | Integer | `3600` | MX DNS cache TTL in seconds (1 hour) |
| `cleanup_interval` | Integer | `3600` | Cleanup task interval in seconds (1 hour) |

### Example Configuration

```yaml
# config/postal/postal.yml
postal:
  mx_rate_limiting:
    enabled: true
    shadow_mode: false
    delay_increment: 300      # 5 minutes per error
    max_delay: 3600           # max 1 hour delay
    recovery_threshold: 5     # 5 successes to recover
    delay_decrement: 120      # -2 minutes per recovery
    mx_cache_ttl: 3600        # 1 hour DNS cache
    cleanup_interval: 3600    # cleanup every hour
```

---

## 🧪 Testing Strategy

### Unit Tests

#### MxRateLimit Model Tests

**File:** `spec/models/mx_rate_limit_spec.rb`

**Test Coverage:**
- ✅ Validations (presence, uniqueness)
- ✅ `#record_error` increments error_count
- ✅ `#record_error` resets success_count
- ✅ `#record_error` increases delay by DELAY_INCREMENT
- ✅ `#record_error` caps delay at MAX_DELAY
- ✅ `#record_error` creates event
- ✅ `#record_success` increments success_count
- ✅ `#record_success` resets error_count
- ✅ `#record_success` decreases delay when threshold reached
- ✅ `#record_success` does not go below zero delay
- ✅ `.rate_limited?` returns true for active limits
- ✅ `.rate_limited?` returns false for inactive limits

#### MxRateLimitPattern Model Tests

**File:** `spec/models/mx_rate_limit_pattern_spec.rb`

**Test Coverage:**
- ✅ Validations
- ✅ `#match?` correctly identifies matching messages
- ✅ `.match_message` returns highest priority match
- ✅ `.match_message` respects enabled flag
- ✅ `.create_defaults!` creates all default patterns

#### MxDomainResolver Service Tests

**File:** `spec/services/mx_domain_resolver_spec.rb`

**Test Coverage:**
- ✅ Resolves MX domain correctly
- ✅ Extracts main domain from MX hostname
- ✅ Caches results
- ✅ Returns cached result when not expired
- ✅ Re-resolves when cache expired
- ✅ Handles DNS resolution failures gracefully

### Integration Tests

#### OutgoingMessageProcessor Tests

**File:** `spec/lib/message_dequeuer/outgoing_message_processor_spec.rb`

**Test Coverage:**
- ✅ Resolves MX domain on processing
- ✅ Skips sending when MX is rate limited
- ✅ Applies rate limit on SMTP error with matching pattern
- ✅ Records success and reduces delay on successful delivery
- ✅ Requeues other messages to same MX when rate limit applied
- ✅ Does not apply rate limit when pattern doesn't match
- ✅ Respects manual flag (bypasses rate limiting)

### Factory Definitions

**File:** `spec/factories/mx_rate_limits.rb`

```ruby
FactoryBot.define do
  factory :mx_rate_limit do
    association :server
    mx_domain { "google.com" }
    current_delay { 0 }
    error_count { 0 }
    success_count { 0 }

    trait :active do
      current_delay { 300 }
      error_count { 1 }
    end

    trait :heavily_throttled do
      current_delay { 3600 }
      error_count { 10 }
    end
  end
end
```

---

## 🚀 Implementation Plan

### Phase 1: Database & Models (Week 1)

**Tasks:**
1. Create database migrations
2. Run migrations in development
3. Implement `MxRateLimit` model
4. Implement `MxRateLimitPattern` model with defaults
5. Implement `MxRateLimitEvent` model
6. Implement `MxDomainCache` model
7. Write unit tests for all models
8. Update schema annotations

**Deliverables:**
- ✅ 5 migrations created and tested
- ✅ 4 models with validations and methods
- ✅ 100% unit test coverage
- ✅ Schema annotations up to date

### Phase 2: Services & Integration (Week 2)

**Tasks:**
1. Implement `MxDomainResolver` service
2. Add methods to `QueuedMessage` model
3. Modify `OutgoingMessageProcessor`
   - Add `resolve_mx_domain` step
   - Add `skip_if_mx_rate_limited` step
   - Add `handle_mx_rate_limit_response` step
4. Write integration tests
5. Test with WebMock for DNS stubbing

**Deliverables:**
- ✅ DNS resolution service working
- ✅ Integration into message processing pipeline
- ✅ Integration tests passing
- ✅ Backward compatibility maintained

### Phase 3: API & Monitoring (Week 3)

**Tasks:**
1. Create API controller for rate limits
2. Implement 3 API endpoints (list, stats, summary)
3. Create scheduled cleanup task
4. Add task to configuration
5. Test API endpoints with RSpec request specs
6. Create simple UI view (optional)

**Deliverables:**
- ✅ REST API functional
- ✅ Cleanup task scheduled
- ✅ API documentation
- ✅ Postman/curl examples

### Phase 4: Testing & Documentation (Week 4)

**Tasks:**
1. End-to-end testing in development
2. Staging deployment
3. Monitor with real traffic (shadow mode)
4. Fix any bugs found
5. Update documentation
6. Prepare production deployment

**Deliverables:**
- ✅ E2E tests passing
- ✅ Staging validated
- ✅ Documentation complete
- ✅ Ready for production

### Phase 5: Production Rollout (Week 5)

**Deployment Strategy:**

1. **Day 1**: Deploy with `shadow_mode: true`
   - System logs rate limit decisions
   - No actual throttling applied
   - Monitor logs for false positives

2. **Day 2-3**: Analyze shadow mode data
   - Review matched patterns
   - Check for unexpected matches
   - Tune patterns if needed

3. **Day 4**: Enable for 10% of servers
   - Set `enabled: true` for select servers
   - Monitor delivery metrics
   - Watch for issues

4. **Day 5-7**: Gradual rollout
   - Increase to 50% of servers
   - Monitor bounce rates, delivery times
   - Compare with control group

5. **Day 8+**: Full deployment
   - Enable for all servers
   - Continue monitoring
   - Iterate on patterns based on feedback

**Rollback Plan:**
- Set `enabled: false` in config
- Messages will revert to old `DomainThrottle` system
- No data loss (rate limit state preserved)

---

## 🔒 Security & Privacy Considerations

### Data Privacy

1. **SMTP Response Logging**
   - Truncate to 512 characters max
   - Do not log email addresses beyond what's in queued_message
   - Auto-delete events after 30 days

2. **DNS Resolution**
   - Cache results to minimize external DNS queries
   - No sensitive data in MX cache table
   - Use system DNS resolver (respects /etc/hosts, etc.)

### Performance

1. **Database Indexes**
   - All foreign keys indexed
   - Composite index on (server_id, mx_domain)
   - Query patterns optimized

2. **Caching Strategy**
   - MX domain cached in queued_message (no repeated lookups)
   - DNS cache table with 1-hour TTL
   - Rate limit checked once per message

3. **Cleanup**
   - Automatic cleanup of old data
   - Prevents table bloat
   - Runs during low-traffic hours (configurable)

### Error Handling

1. **DNS Resolution Failures**
   - Fallback to recipient domain
   - Log error, don't block message processing
   - Continue with existing retry logic

2. **Pattern Matching Failures**
   - Invalid regex logged, pattern disabled
   - Fallback to existing DomainThrottle system
   - Admin notified via logs

3. **Database Errors**
   - Transaction rollbacks on failure
   - Message remains in queue
   - Retry on next worker cycle

---

## 📊 Success Metrics

### Key Performance Indicators (KPIs)

1. **Delivery Success Rate**
   - Target: Maintain or improve current rate
   - Measure: Successful deliveries / total attempts
   - Goal: Rate limiting reduces failed attempts

2. **Average Delivery Time**
   - Target: No significant increase for successful deliveries
   - Measure: Time from queue to delivery
   - Acceptable: +5% for throttled domains, -10% overall

3. **Bounce Rate Reduction**
   - Target: 20% reduction in soft bounces due to rate limiting
   - Measure: Soft bounce count before/after
   - Goal: Fewer "try again later" bounces

4. **Active Rate Limits**
   - Measure: Number of MX domains currently throttled
   - Baseline: Establish in shadow mode
   - Monitor: Should correlate with large provider rate limits

5. **Recovery Time**
   - Measure: Time from first error to delay=0
   - Target: < 30 minutes average
   - Goal: Quick recovery when conditions improve

### Monitoring Dashboards

**Metrics to Display:**
- Active rate limits count
- Top 10 throttled MX domains
- Error events in last 24h
- Success events in last 24h
- Average current delay
- Messages delayed by rate limiting
- Recovery events (delay decreased)

---

## 🔄 Backward Compatibility

### Coexistence with DomainThrottle

The new MX rate limiting system coexists with the existing `DomainThrottle` system:

1. **Both systems active**: Messages checked against both
2. **Independent operation**: Each system maintains own state
3. **Separate tables**: No schema conflicts
4. **Graceful degradation**: If MX system disabled, DomainThrottle continues

### Migration Path

**No data migration required** - this is a new system.

**Optional cleanup** after validation:
- DomainThrottle can be deprecated after 6 months
- Cleanup task can remove old domain_throttles table
- Not required for operation

### Configuration Flags

```yaml
# Run both systems (default)
postal:
  mx_rate_limiting:
    enabled: true
  domain_throttling:
    enabled: true  # existing system

# MX only (after validation)
postal:
  mx_rate_limiting:
    enabled: true
  domain_throttling:
    enabled: false

# Rollback to old system
postal:
  mx_rate_limiting:
    enabled: false
  domain_throttling:
    enabled: true
```

---

## 📝 Open Questions & Future Enhancements

### Open Questions

1. **MX Domain Extraction**
   - Current: Simple "last 2 parts" extraction
   - Question: Use `public_suffix` gem for accuracy?
   - Trade-off: Dependency vs. accuracy

2. **Pattern Management UI**
   - Current: Database-only management
   - Question: Build admin UI for pattern management?
   - Trade-off: Development time vs. ease of use

3. **Per-Organization Limits**
   - Current: Per-server rate limiting
   - Question: Should organizations share rate limits?
   - Trade-off: Isolation vs. collective benefit

### Future Enhancements

1. **Machine Learning Pattern Detection** (v2.0)
   - Auto-detect new rate limit patterns
   - Suggest new patterns to admins
   - Reduce manual pattern maintenance

2. **Time-of-Day Awareness** (v2.0)
   - Different limits for peak/off-peak hours
   - Historical analysis of MX behavior
   - Predictive throttling

3. **IP-level Rate Limiting** (v2.0)
   - Track rate limits per sending IP
   - Rotate IPs more intelligently
   - Coordinate with IP pool management

4. **Shared Intelligence** (v3.0)
   - Optional: Share rate limit data across Postal instances
   - Community-driven pattern database
   - Privacy-preserving aggregation

5. **Advanced Recovery Strategies** (v2.0)
   - Exponential recovery (faster initially)
   - Test messages to probe readiness
   - Adaptive thresholds based on MX behavior

---

## 📚 References

### Related Documentation

- [Domain Throttling (existing)](doc/DOMAIN_THROTTLING.md)
- [Message Processing Flow](doc/MESSAGE_PROCESSING.md)
- [SMTP Sender Implementation](doc/SMTP_SENDER.md)

### External Resources

- [RFC 5321 - SMTP](https://tools.ietf.org/html/rfc5321)
- [RFC 7489 - DMARC](https://tools.ietf.org/html/rfc7489)
- [Gmail Bulk Sender Guidelines](https://support.google.com/mail/answer/81126)
- [Postfix Rate Limiting](http://www.postfix.org/TUNING_README.html#sending_rate)

### SMTP Response Codes Reference

| Code | Type | Meaning |
|------|------|---------|
| 421 | Temporary | Service not available, try later |
| 450 | Temporary | Mailbox unavailable |
| 451 | Temporary | Action aborted, try later |
| 452 | Temporary | Insufficient system storage |
| 550 | Permanent | Mailbox unavailable |
| 551 | Permanent | User not local |
| 552 | Permanent | Exceeded storage allocation |
| 553 | Permanent | Mailbox name not allowed |

---

## ✅ Acceptance Criteria

This feature will be considered complete when:

- [ ] All database migrations run successfully
- [ ] All models implemented with full test coverage
- [ ] MX domain resolution working with caching
- [ ] Integration into OutgoingMessageProcessor complete
- [ ] Pattern matching correctly identifies rate limits
- [ ] Linear backoff increases delay on errors
- [ ] Gradual recovery decreases delay on successes
- [ ] Messages requeued when MX is throttled
- [ ] API endpoints functional and documented
- [ ] Scheduled cleanup task running
- [ ] Shadow mode testing completed
- [ ] Production deployment successful
- [ ] Metrics dashboard showing data
- [ ] Documentation complete and reviewed
- [ ] No degradation in delivery performance
- [ ] 20% reduction in soft bounces achieved

---

## 📞 Contact & Support

**Project Owner:** TBD  
**Technical Lead:** TBD  
**Review Status:** Draft - Pending Review  
**Last Updated:** 2026-01-23

---

**Document Version:** 1.0.0  
**Status:** Ready for Technical Review
