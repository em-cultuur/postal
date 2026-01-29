# SMTP Response Pattern Recognition

This document details the SMTP response patterns recognized by the IP Blacklist Management system's Phase 6 implementation.

## Overview

The `IPBlacklist::SmtpResponseParser` analyzes SMTP error messages in real-time during mail delivery to detect:
- Explicit blacklist rejections (Spamhaus, Barracuda, SORBS, etc.)
- Provider-specific reputation blocks (Gmail, Outlook, Yahoo)
- Soft vs. hard bounce classification
- Severity assessment (low, medium, high)

## Pattern Priority

Patterns are checked in the following order:
1. **Provider-specific patterns** (Gmail, Outlook, Yahoo) - most specific
2. **Generic DNSBL patterns** - fallback for explicit DNSBL references

This ensures that provider-specific patterns (like Gmail's "Our system has detected...") take precedence over generic patterns.

---

## Gmail Patterns

### 1. Rate Limiting
**Pattern:** `421-4.7.0 ... rate limit ... exceeded`

**Example:**
```
421-4.7.0 [192.0.2.1] Our system has detected that this message is 
suspicious due to rate limit exceeded. Try again later.
```

**Detection:**
- **Source:** `gmail_rate_limit`
- **Severity:** Medium
- **Bounce Type:** Soft (421)
- **Suggested Action:** Monitor closely, track soft bounces

**Description:** Gmail has detected an unusual rate of emails from this IP and is temporarily throttling delivery.

---

### 2. Temporary Block
**Pattern:** `421-4.7.0 ... Try again later`

**Example:**
```
421-4.7.0 Try again later, closing connection.
```

**Detection:**
- **Source:** `gmail_temporary_block`
- **Severity:** High
- **Bounce Type:** Soft (421)
- **Suggested Action:** Track soft bounces, pause after threshold

**Description:** Gmail has temporarily blocked the IP due to reputation issues.

---

### 3. Suspicious Activity
**Pattern:** `550-5.7.1 ... Our system has detected ... suspicious`

**Example:**
```
550-5.7.1 Our system has detected an unusual rate of suspicious emails 
originating from your IP address. To protect our users from spam, mail 
sent from your IP address has been blocked.
```

**Detection:**
- **Source:** `gmail_suspicious_activity`
- **Severity:** High
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause immediately

**Description:** Gmail has detected suspicious sending patterns and permanently blocked the IP.

---

### 4. Policy Block
**Pattern:** `550-5.7.1 ... email ... blocked ... policy`

**Example:**
```
550-5.7.1 The email account that you tried to reach is blocked due to 
policy that prohibits mail from your IP address.
```

**Detection:**
- **Source:** `gmail_policy_block`
- **Severity:** High
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause immediately

**Description:** Gmail has blocked the IP based on internal policies.

---

### 5. Authentication Failure
**Pattern:** `550-5.7.26 ... message ... not pass authentication`

**Example:**
```
550-5.7.26 This message does not pass authentication checks (SPF and 
DKIM both do not pass). Please visit https://support.google.com/mail/
answer/81126#authentication for more information.
```

**Detection:**
- **Source:** `gmail_authentication_failure`
- **Severity:** Medium
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause after threshold

**Description:** Message failed SPF/DKIM/DMARC authentication checks.

---

## Outlook/Hotmail Patterns

### 1. IP Blocked
**Pattern:** `550-5.7.1 Service unavailable ... Client host ... rejected`

**Example:**
```
550 5.7.1 Service unavailable; Client host [192.0.2.1] rejected due to 
poor reputation.
```

**Detection:**
- **Source:** `outlook_ip_blocked`
- **Severity:** High
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause immediately

**Description:** Outlook has blocked the IP due to poor reputation.

---

### 2. IP Reputation Block
**Pattern:** `550-5.7.1 ... blocked ... IP reputation`

**Example:**
```
550 5.7.1 Message blocked due to IP reputation issues. Please visit 
https://postmaster.live.com/snds/ for more information.
```

**Detection:**
- **Source:** `outlook_reputation_block`
- **Severity:** High
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause immediately

**Description:** Message blocked due to SNDS reputation score.

---

### 3. DNSBL Block
**Pattern:** `550 ... (BAY\d+) ... block list ... DNSBL`

**Example:**
```
550 SC-001 (BAY004) Unfortunately, messages from [192.0.2.1] weren't sent. 
Please contact your Internet service provider since part of their network 
is on our block list (S3140). DNSBL issue.
```

**Detection:**
- **Source:** `outlook_dnsbl_block`
- **Severity:** High
- **Bounce Type:** Hard (550)
- **Suggested Action:** Pause immediately

**Description:** IP is listed on a DNSBL checked by Outlook.

---

### 4. Temporary Deferral
**Pattern:** `421-4.3.2 ... temporarily deferred`

**Example:**
```
421 4.3.2 Service not available, temporarily deferred.
```

**Detection:**
- **Source:** `outlook_temporary_defer`
- **Severity:** Medium
- **Bounce Type:** Soft (421)
- **Suggested Action:** Monitor closely

**Description:** Temporary service issue or possible reputation concern.

---

## Yahoo Patterns

### 1. Throttling
**Pattern:** `421-4.7.0 [TS\d+]`

**Example:**
```
421 4.7.0 [TS03] Messages from 192.0.2.1 temporarily deferred due to 
user complaints - 4.16.55.1.
```

**Detection:**
- **Source:** `yahoo_throttle`
- **Severity:** Medium
- **Bounce Type:** Soft (421)
- **Suggested Action:** Monitor closely

**Description:** Yahoo is throttling due to volume or user complaints.

---

### 2. Policy Block
**Pattern:** `554-5.7.9 ... Message not accepted for policy reasons`

**Example:**
```
554 5.7.9 Message not accepted for policy reasons. See 
http://help.yahoo.com/l/us/yahoo/mail/postmaster/errors/postmaster-28.html
```

**Detection:**
- **Source:** `yahoo_policy_block`
- **Severity:** High
- **Bounce Type:** Hard (554)
- **Suggested Action:** Pause immediately

**Description:** Message rejected due to Yahoo policy violations.

---

### 3. Spam Block
**Pattern:** `553 ... spam ... blocked`

**Example:**
```
553 Mail from 192.0.2.1 rejected due to spam content blocked.
```

**Detection:**
- **Source:** `yahoo_spam_block`
- **Severity:** High
- **Bounce Type:** Hard (553)
- **Suggested Action:** Pause immediately

**Description:** Message detected as spam by Yahoo filters.

---

## Generic DNSBL Patterns

These patterns match explicit DNSBL references in SMTP responses.

### Spamhaus
- **ZEN:** `/zen\.spamhaus\.org/i` → `spamhaus_zen`
- **SBL:** `/sbl\.spamhaus\.org/i` → `spamhaus_sbl`
- **XBL:** `/xbl\.spamhaus\.org/i` → `spamhaus_xbl`
- **PBL:** `/pbl\.spamhaus\.org/i` → `spamhaus_pbl`

**Example:**
```
554 Service unavailable; Client host [192.0.2.1] blocked using 
zen.spamhaus.org; https://www.spamhaus.org/query/ip/192.0.2.1
```

### Other DNSBLs
- **SpamCop:** `/bl\.spamcop\.net/i` → `spamcop`
- **Barracuda:** `/b\.barracudacentral\.org/i` → `barracuda`
- **SORBS:** `/dnsbl\.sorbs\.net/i` → `sorbs`
- **PSBL:** `/psbl\.surriel\.com/i` → `psbl`
- **URIBL:** `/uribl\.com/i` → `uribl`
- **SURBL:** `/multi\.surbl\.org/i` → `surbl`
- **Mailspike:** `/bl\.mailspike\.net/i` → `mailspike`

### Generic Patterns
- **Generic DNSBL:** `/dnsbl/i` → `generic_dnsbl`
- **Generic Blacklist:** `/blacklist/i` → `generic_blacklist`
- **Generic Blocklist:** `/blocklist/i` → `generic_blocklist`
- **Generic RBL:** `/\bRBL\b/i` → `generic_rbl`

---

## SMTP Code Classification

### Soft Bounce Codes (Temporary Failures)
- **421** - Service not available, closing connection
- **450** - Requested action not taken: mailbox unavailable
- **451** - Requested action aborted: local error in processing
- **452** - Requested action not taken: insufficient system storage

**Handling:** Track occurrences; pause IP for domain after threshold (default: 5 in 60 minutes)

### Hard Bounce Codes (Permanent Failures)
- **550** - Requested action not taken: mailbox unavailable
- **551** - User not local; please try forward path
- **552** - Requested action aborted: exceeded storage allocation
- **553** - Requested action not taken: mailbox name not allowed
- **554** - Transaction failed

**Handling:** Immediate pause for high-severity blacklist detections

---

## Severity Levels

### High Severity
- Explicit blacklist references (Spamhaus, Barracuda, etc.)
- Provider-specific IP blocks (Gmail suspicious activity, Outlook reputation block)
- Policy violations

**Action:** Immediate pause for hard bounces; track and pause after threshold for soft bounces

### Medium Severity
- Rate limiting (Gmail, Yahoo)
- Authentication failures
- Temporary deferrals with reputation hints

**Action:** Monitor closely; pause after multiple occurrences

### Low Severity
- Generic rejections without blacklist indicators
- Non-reputation-related errors

**Action:** Monitor only

---

## Configuration

Configure SMTP response analysis in `config/postal/postal.yml`:

```yaml
ip_reputation:
  smtp_response_analysis:
    enabled: true
    soft_bounce_threshold: 5       # Trigger pause after N soft bounces
    soft_bounce_window_minutes: 60 # Within this time window
    auto_pause_on_hard_bounce: true # Pause immediately on high-severity hard bounce
```

---

## Usage Example

```ruby
# Parse an SMTP error
smtp_code = "550"
smtp_message = "550-5.7.1 Our system has detected suspicious emails from your IP."

result = IPBlacklist::SmtpResponseParser.parse(smtp_message, smtp_code)

if result[:blacklist_detected]
  puts "Blacklist detected!"
  puts "Source: #{result[:blacklist_source]}"
  puts "Severity: #{result[:severity]}"
  puts "Suggested action: #{result[:suggested_action]}"
end
```

---

## Testing

Comprehensive tests in `spec/lib/ip_blacklist/smtp_response_parser_spec.rb` cover:
- All provider-specific patterns (Gmail, Outlook, Yahoo)
- All generic DNSBL patterns
- Bounce type detection
- Severity classification
- Suggested action logic
- Pattern priority

Run tests:
```bash
bundle exec rspec spec/lib/ip_blacklist/smtp_response_parser_spec.rb
```

---

## Adding New Patterns

To add support for a new email provider:

1. **Add pattern to parser:**
```ruby
NEW_PROVIDER_PATTERNS = [
  {
    regex: /pattern to match/i,
    source: "provider_issue_name",
    severity: "high",
    description: "Human-readable description"
  }
].freeze
```

2. **Add checker method:**
```ruby
def self.check_new_provider_patterns(message, result)
  NEW_PROVIDER_PATTERNS.each do |pattern|
    if message =~ pattern[:regex]
      result[:blacklist_detected] = true
      result[:blacklist_source] = pattern[:source]
      result[:severity] = pattern[:severity]
      result[:description] = pattern[:description]
      return true
    end
  end
  false
end
```

3. **Update parse method:**
```ruby
check_new_provider_patterns(message, result) ||
  check_gmail_patterns(message, result) ||
  # ... existing patterns
```

4. **Add tests** in `spec/lib/ip_blacklist/smtp_response_parser_spec.rb`

---

## Performance Considerations

- Pattern matching is performed **inline during SMTP delivery**
- All regex patterns are case-insensitive (`/i` flag)
- Patterns are checked in priority order (provider-specific first)
- First match wins (short-circuit evaluation)
- Typical parsing time: < 1ms per error

---

## Monitoring

Track SMTP response analysis effectiveness:

```ruby
# Count detections by source
IPBlacklistRecord.from_smtp.group(:blacklist_source).count

# Recent SMTP rejections
SMTPRejectionEvent.recent.hard_bounces

# Soft bounce trends
SMTPRejectionEvent.soft_bounces.for_domain("gmail.com").recent(24.hours.ago)
```
