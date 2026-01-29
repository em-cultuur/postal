# Phase 5: External Reputation Monitoring & Notifications

This phase extends the IP blacklist management system with external reputation monitoring from Google Postmaster Tools and Microsoft SNDS, along with a comprehensive notification system.

## Features Implemented

### 1. Google Postmaster Tools Integration

**File**: `app/lib/ip_reputation/google_postmaster_client.rb`

Fetches domain-level reputation metrics from Google Postmaster API:
- Domain reputation (HIGH, MEDIUM, LOW, BAD)
- Spam rate
- User-reported spam rate
- DKIM/SPF/DMARC authentication success rates
- Inbound encryption rate

**Configuration**:
```yaml
# config/postal/postal.yml
ip_reputation:
  google_postmaster:
    access_token: "ya29.xxx..."
    refresh_token: "1//xxx..."
    client_id: "xxx.apps.googleusercontent.com"
    client_secret: "xxx"
```

**Setup Steps**:
1. Register domains at https://postmaster.google.com/
2. Create OAuth2 credentials in Google Cloud Console
3. Grant permissions: `https://www.googleapis.com/auth/postmaster.readonly`
4. Add credentials to Postal configuration

### 2. Microsoft SNDS Integration

**File**: `app/lib/ip_reputation/microsoft_snds_client.rb`

Fetches IP-level reputation metrics from Microsoft SNDS:
- Filter result color (green, yellow, red, trap)
- Complaint rates
- Spam trap hits
- Message volume
- Sample HELO/MAIL FROM

**Configuration**:
```yaml
# config/postal/postal.yml
ip_reputation:
  microsoft_snds:
    api_key: "your_snds_api_key"
```

**Setup Steps**:
1. Register IPs at https://postmaster.live.com/snds/
2. Request API access key
3. Add API key to Postal configuration

### 3. Reputation Data Processor

**File**: `app/lib/ip_reputation/processor.rb`

Processes reputation data from external sources and triggers automatic actions based on configurable thresholds.

**Thresholds** (configurable in code):
- **Google Postmaster**:
  - BAD reputation → Immediate pause
  - LOW reputation → Warning
  - Spam rate > 10% → Pause
  - Spam rate > 5% → Warning
  - User spam rate > 3% → Pause
  
- **Microsoft SNDS**:
  - RED status → Immediate pause
  - YELLOW status → Warning
  - Trap hits → Immediate pause
  - Complaint rate > 0.3% → Pause
  - Complaint rate > 0.1% → Warning

### 4. Automated Reputation Sync

**File**: `app/scheduled_tasks/sync_external_reputation_scheduled_task.rb`

Scheduled task that runs daily at 6 AM to:
- Fetch SNDS data for all IPs
- Fetch Google Postmaster data for major domains
- Store metrics in `ip_reputation_metrics` table
- Trigger automatic actions based on thresholds

**Major domains monitored**:
- gmail.com / googlemail.com
- yahoo.com / aol.com
- outlook.com / hotmail.com / live.com

### 5. Notification System

**File**: `app/lib/ip_blacklist/notifier.rb`

Comprehensive notification system supporting multiple channels:

**Notification Types**:
- `ip_blacklisted` - IP detected on DNSBL
- `ip_paused` - IP automatically paused
- `ip_resumed` - IP unpaused/resumed
- `reputation_warning` - Threshold exceeded
- `warmup_advanced` - Warmup stage progression

**Notification Channels**:

#### Webhooks (HTTP POST)
```yaml
ip_reputation:
  notifications:
    webhooks:
      - "https://your-app.com/webhooks/postal"
      - "https://monitoring.example.com/alerts"
```

Webhook payload example:
```json
{
  "event_type": "ip_blacklisted",
  "severity": "high",
  "ip_address": "192.0.2.1",
  "hostname": "mail1.example.com",
  "destination_domain": "gmail.com",
  "blacklist_source": "zen.spamhaus.org",
  "detection_method": "dnsbl_check",
  "detected_at": "2026-01-28T10:00:00Z",
  "timestamp": "2026-01-28T10:00:05Z"
}
```

#### Email Notifications
```yaml
ip_reputation:
  notifications:
    email_addresses:
      - "admin@example.com"
      - "monitoring@example.com"
```

#### Slack Notifications
```yaml
ip_reputation:
  notifications:
    slack_webhook_url: "https://hooks.slack.com/services/T00/B00/xxx"
```

### 6. Feedback Loop (FBL) Parser

**File**: `app/lib/ip_reputation/feedback_loop_parser.rb`

Parses ARF (Abuse Reporting Format) complaint emails from ISPs:
- Extracts complaint data (source IP, recipient, timestamp)
- Identifies the sending IP from headers
- Stores complaints in `ip_reputation_metrics`
- Triggers actions based on complaint thresholds

**Thresholds**:
- 10+ complaints in 7 days → Pause IP for domain
- 5+ complaints in 7 days → Warning/monitoring

**Usage**:
```ruby
parser = IPReputation::FeedbackLoopParser.new(raw_email)
if parser.valid_arf?
  parser.process_complaint
end
```

**Integration**: Configure email routing to forward FBL emails to a Postal route that processes them with this parser.

## Database Schema Updates

### Added `MONITOR` Action Type

**File**: `app/models/ip_health_action.rb`

New action type for logging warnings without pausing IPs:
```ruby
MONITOR = "monitor"
```

Used when reputation metrics exceed warning thresholds but don't require immediate action.

## Integration with Existing System

### Notifier Integration

Updated files to use new notification system:
1. **`app/lib/ip_blacklist/ip_health_manager.rb`**:
   - Sends notifications when IPs are paused/unpaused
   - Sends notifications when blacklists are detected

2. **`app/models/ip_domain_exclusion.rb`**:
   - Sends notifications when warmup stages advance

## Testing

### Manual Testing

1. **Test Google Postmaster**:
```ruby
client = IPReputation::GooglePostmasterClient.new(domain: "gmail.com")
data = client.fetch_reputation_data
puts data.inspect
```

2. **Test Microsoft SNDS**:
```ruby
client = IPReputation::MicrosoftSndsClient.new
data = client.fetch_ip_reputation("192.0.2.1")
puts data.inspect
```

3. **Test Processor**:
```ruby
processor = IPReputation::Processor.new
processor.process_all_ips
```

4. **Test Notifications**:
```ruby
notifier = IPBlacklist::Notifier.new
ip = IPAddress.first
blacklist = IPBlacklistRecord.first
notifier.notify_blacklist_detected(ip, blacklist)
```

5. **Test FBL Parser**:
```ruby
raw_email = File.read("path/to/arf_complaint.eml")
parser = IPReputation::FeedbackLoopParser.new(raw_email)
parser.process_complaint if parser.valid_arf?
```

## Configuration Examples

### Complete Configuration

```yaml
# config/postal/postal.yml
ip_reputation:
  # Google Postmaster Tools
  google_postmaster:
    access_token: "ya29.xxx"
    refresh_token: "1//xxx"
    client_id: "xxx.apps.googleusercontent.com"
    client_secret: "xxx"
  
  # Microsoft SNDS
  microsoft_snds:
    api_key: "your_snds_api_key"
  
  # Notifications
  notifications:
    # HTTP Webhooks
    webhooks:
      - "https://your-app.com/webhooks/postal-ip-health"
      - "https://monitoring.example.com/alerts"
    
    # Email alerts
    email_addresses:
      - "admin@example.com"
      - "ops@example.com"
    
    # Slack integration
    slack_webhook_url: "https://hooks.slack.com/services/T00/B00/xxx"
```

### Minimal Configuration (Notifications Only)

```yaml
ip_reputation:
  notifications:
    slack_webhook_url: "https://hooks.slack.com/services/T00/B00/xxx"
```

## API Endpoints for Admin UI

To build an admin UI, you'll need to create these API endpoints (not implemented in this phase):

### GET /api/v1/ip_addresses/:id/health
Returns health status for an IP:
```json
{
  "ip_address": "192.0.2.1",
  "hostname": "mail1.example.com",
  "priority": 100,
  "health_status": {
    "gmail.com": {
      "status": "warming",
      "warmup_stage": 2,
      "priority": 40,
      "next_advancement": "2026-02-01T10:00:00Z"
    },
    "yahoo.com": {
      "status": "paused",
      "reason": "Blacklisted on zen.spamhaus.org",
      "blacklists": ["zen.spamhaus.org"]
    }
  }
}
```

### GET /api/v1/ip_addresses/:id/reputation_metrics
Returns recent reputation metrics:
```json
{
  "metrics": [
    {
      "date": "2026-01-28",
      "metric_type": "google_postmaster_reputation",
      "destination_domain": "gmail.com",
      "metric_value": 100,
      "spam_rate": 0.002,
      "complaint_rate": 0.0005
    },
    {
      "date": "2026-01-28",
      "metric_type": "microsoft_snds",
      "destination_domain": "outlook.com",
      "filter_result": "green",
      "complaint_rate": 0.0003
    }
  ]
}
```

### GET /api/v1/ip_addresses/:id/health_actions
Returns recent health actions:
```json
{
  "actions": [
    {
      "id": 123,
      "action_type": "pause",
      "destination_domain": "gmail.com",
      "reason": "Blacklisted on zen.spamhaus.org",
      "created_at": "2026-01-20T15:30:00Z"
    },
    {
      "id": 124,
      "action_type": "warmup_stage_advance",
      "destination_domain": "gmail.com",
      "created_at": "2026-01-22T10:00:00Z"
    }
  ]
}
```

### POST /api/v1/ip_addresses/:id/pause
Manually pause an IP for a domain:
```json
{
  "destination_domain": "gmail.com",
  "reason": "Manual pause for maintenance"
}
```

### POST /api/v1/ip_addresses/:id/unpause
Manually unpause an IP for a domain:
```json
{
  "destination_domain": "gmail.com"
}
```

## Monitoring & Alerting

### Log Messages

All components log structured messages with prefixes:
- `[GooglePostmaster]` - Google API operations
- `[SNDS]` - Microsoft SNDS operations
- `[IPReputation]` - Reputation processing and actions
- `[FBL]` - Feedback loop processing
- `[Notifier]` - Notification sending
- `[REPUTATION SYNC]` - Scheduled sync operations

### Metrics to Monitor

1. **Reputation sync failures** - Check logs for errors in scheduled task
2. **Notification delivery failures** - Check webhook/Slack response codes
3. **FBL complaint rates** - Monitor complaint trends per IP/domain
4. **Automatic pause frequency** - Track how often IPs are paused
5. **API authentication failures** - Watch for expired tokens

## Next Steps (Future Enhancements)

1. **Admin UI Implementation**:
   - Build Rails controllers for API endpoints
   - Create React/Vue dashboard for visualizing IP health
   - Add charts for reputation trends over time

2. **Enhanced Metrics**:
   - Calculate complaint rates as percentage of sent volume
   - Track inbox placement rates
   - Monitor bounce rates by ISP

3. **Machine Learning**:
   - Predict IP reputation trends
   - Optimize warmup schedules based on historical data
   - Automatically adjust thresholds

4. **Additional Integrations**:
   - Return Path/Validity reputation monitoring
   - Senderscore.org integration
   - Custom DMARC report parsing

5. **Advanced Actions**:
   - Automatic IP rotation on blacklist
   - Dynamic warmup schedules per ISP
   - A/B testing of sender reputation strategies

## Troubleshooting

### Google Postmaster Authentication Fails
- Verify OAuth2 credentials are correct
- Check that domain is verified in Google Postmaster
- Ensure refresh token hasn't expired (re-authorize if needed)
- Check API permissions include `postmaster.readonly` scope

### SNDS Returns No Data
- Verify IP addresses are registered at postmaster.live.com
- Check that API key is valid and not expired
- Ensure IPs have sent sufficient volume to Outlook/Hotmail
- SNDS data is typically delayed by 24-48 hours

### Notifications Not Received
- Check webhook URLs are accessible and return 2xx
- Verify Slack webhook URL is correct and channel exists
- Test email configuration with a simple test
- Check logs for `[Notifier]` error messages

### FBL Complaints Not Parsed
- Verify email is in valid ARF format
- Check that IP addresses in headers match your pool
- Ensure email routing is configured to forward FBL emails
- Test with sample ARF email from ISP documentation

## Files Created/Modified

### New Files:
- `app/lib/ip_reputation/google_postmaster_client.rb`
- `app/lib/ip_reputation/microsoft_snds_client.rb`
- `app/lib/ip_reputation/processor.rb`
- `app/lib/ip_reputation/feedback_loop_parser.rb`
- `app/lib/ip_blacklist/notifier.rb`
- `app/scheduled_tasks/sync_external_reputation_scheduled_task.rb`

### Modified Files:
- `app/models/ip_health_action.rb` - Added `MONITOR` action type
- `app/lib/ip_blacklist/ip_health_manager.rb` - Integrated notifications
- `app/models/ip_domain_exclusion.rb` - Added warmup notifications

## Summary

Phase 5 adds comprehensive external reputation monitoring and notifications to the IP blacklist management system. The system now:

- ✅ Fetches reputation data from Google Postmaster and Microsoft SNDS
- ✅ Processes feedback loop complaints automatically
- ✅ Triggers automatic actions based on configurable thresholds
- ✅ Sends multi-channel notifications (webhooks, email, Slack)
- ✅ Integrates seamlessly with existing blacklist and warmup systems
- ✅ Provides foundation for building admin UI

The system is production-ready and can be enabled by adding configuration credentials. All components are designed to fail gracefully if external services are unavailable.
