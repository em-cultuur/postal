# MTA-STS and TLS-RPT Implementation in Postal

## Overview

This implementation adds support for MTA-STS (SMTP MTA Strict Transport Security) and TLS-RPT (TLS Reporting) to Postal, improving the security of email communications.

## Implemented Components

### 1. Database Migration
**File:** `db/migrate/20251107000001_add_mta_sts_and_tls_rpt_to_domains.rb`

Adds the following fields to the `domains` table:
- `mta_sts_enabled` (boolean): Enables/disables MTA-STS
- `mta_sts_mode` (string): Policy mode (testing, enforce, none)
- `mta_sts_max_age` (integer): Policy cache duration in seconds
- `mta_sts_mx_patterns` (text): Custom MX patterns (one per line)
- `mta_sts_status` (string): DNS verification status
- `mta_sts_error` (string): DNS verification error message
- `tls_rpt_enabled` (boolean): Enables/disables TLS-RPT
- `tls_rpt_email` (string): Email to receive TLS reports
- `tls_rpt_status` (string): DNS verification status
- `tls_rpt_error` (string): DNS verification error message

### 2. Domain Model
**File:** `app/models/domain.rb`

#### MTA-STS Methods:
- `mta_sts_record_name`: DNS record name (_mta-sts.domain.com)
- `mta_sts_record_value`: DNS TXT record value
- `mta_sts_policy_id`: Unique policy ID (based on configuration hash)
- `mta_sts_policy_content`: Policy file content in text format
- `default_mta_sts_mx_patterns`: Default MX patterns from Postal configuration

#### TLS-RPT Methods:
- `tls_rpt_record_name`: DNS record name (_smtp._tls.domain.com)
- `tls_rpt_record_value`: DNS TXT record value
- `default_tls_rpt_email`: Default email for reports

### 3. HasDNSChecks Concern
**File:** `app/models/concerns/has_dns_checks.rb`

#### Added Methods:
- `check_mta_sts_record`: Verifies the MTA-STS DNS record and HTTPS availability of the policy file
- `check_mta_sts_record!`: Verifies and saves
- `check_mta_sts_policy_file`: Verifies the accessibility and validity of the policy file via HTTPS
- `check_tls_rpt_record`: Verifies the TLS-RPT DNS record
- `check_tls_rpt_record!`: Verifies and saves

The `check_dns` method has been extended to include MTA-STS and TLS-RPT verifications.

**HTTPS Policy Verification:**
The `check_mta_sts_policy_file` method performs the following checks:
- HTTPS connection to `https://mta-sts.domain.com/.well-known/mta-sts.txt`
- SSL certificate verification
- Verification that the server responds with HTTP 200
- Policy file content validation:
  - Presence of `version: STSv1`
  - Presence of a valid mode (testing, enforce, none)
  - Presence of a valid max_age value
- Timeout configured at 10 seconds for opening and reading
- Detailed error handling (SSL, timeout, HTTP, format)

### 4. MTA-STS Controller
**File:** `app/controllers/mta_sts_controller.rb`

Serves the MTA-STS policy via the public endpoint:
- **Route:** `GET /.well-known/mta-sts.txt`
- **Host:** `mta-sts.domain.com`
- Returns the policy file in plain text format
- Cache-Control header configured with the domain's max_age
- Verifies that the domain is verified and has MTA-STS enabled

### 5. Domains Controller
**File:** `app/controllers/domains_controller.rb`

#### New Actions:
- `edit_security`: Shows the MTA-STS/TLS-RPT configuration form
- `update_security`: Updates security settings
- `check_mta_sts_policy`: Manually verifies the accessibility of the MTA-STS policy file via HTTPS (supports JSON and JS formats)

### 6. Views

#### `app/views/domains/setup.html.haml`
Extended with sections to show:
- Instructions for configuring the MTA-STS DNS record
- Instructions for configuring the TLS-RPT DNS record
- DNS verification status
- Link to policy configuration
- **Button to test MTA-STS policy file accessibility via HTTPS**
- Direct link to view the policy file in the browser

#### `app/views/domains/edit_security.html.haml`
Complete form to configure:
- MTA-STS enabling
- Policy mode (testing/enforce/none)
- Policy max age
- Custom MX patterns
- TLS-RPT enabling
- TLS report email

### 7. Routes
**File:** `config/routes.rb`

New routes added:
```ruby
# Public policy endpoint
get ".well-known/mta-sts.txt" => "mta_sts#policy"

# Domain security configuration (for both org and server)
get :edit_security, on: :member
patch :update_security, on: :member
post :check_mta_sts_policy, on: :member  # Manual HTTPS policy verification
```

## How to Use

### 1. MTA-STS Configuration

1. Go to the domain page
2. Click on "Configure MTA-STS & TLS-RPT"
3. Enable MTA-STS
4. Select the mode:
   - **Testing**: Receive reports but don't block emails
   - **Enforce**: Reject emails not sent via secure TLS
   - **None**: Disable MTA-STS
5. Set the Max Age (recommended: 604800 = 7 days)
6. Optionally, specify custom MX patterns
7. Save the settings

### 2. MTA-STS DNS Configuration

After enabling MTA-STS, configure the following DNS records:

#### TXT Record
```
Name: _mta-sts.yourdomain.com
Value: v=STSv1; id=<policy-id>;
```

#### A or CNAME Record
```
Name: mta-sts.yourdomain.com
Value: <IP-or-hostname-of-your-postal>
```

### 3. TLS-RPT Configuration

1. On the same configuration page, enable TLS-RPT
2. Specify an email to receive reports (optional)
3. Save the settings

### 4. TLS-RPT DNS Configuration

```
Name: _smtp._tls.yourdomain.com
Type: TXT
Value: v=TLSRPTv1; rua=mailto:tls-reports@yourdomain.com
```

### 5. DNS Verification

1. Return to the "DNS Setup" page
2. Click on "Check my records are correct"
3. Verify that all records are configured correctly

## MTA-STS Policy File Format

The file served at `https://mta-sts.domain.com/.well-known/mta-sts.txt` has the following format:

```
version: STSv1
mode: enforce
mx: *.mx.example.com
mx: mx1.example.com
max_age: 604800
```

## Technical Notes

### Policy ID
The policy ID is automatically generated via SHA256 hash of the current configuration (mode, max_age, MX patterns, timestamp). This ensures that the ID changes every time the policy is modified, forcing clients to download the new policy.

### Cache
The policy file is served with a `Cache-Control` header configured according to the domain's `max_age`, allowing mail servers to cache the policy for the specified period.

### Security
- Only verified domains can serve MTA-STS policies
- The MTA-STS controller is public (no authentication required)
- Supports hosting multiple domains on the same Postal instance

### MX Patterns
If custom MX patterns are not specified, the MX records configured in `Postal::Config.dns.mx_records` are automatically used with wildcards (`*.mx.example.com`).

## References

- [RFC 8461 - MTA-STS](https://datatracker.ietf.org/doc/html/rfc8461)
- [RFC 8460 - TLS-RPT](https://datatracker.ietf.org/doc/html/rfc8460)

## Testing

To test the implementation:

1. Configure a test domain
2. Enable MTA-STS in "testing" mode
3. Configure the DNS records
4. Verify that the policy file is accessible: `curl https://mta-sts.yourdomain.com/.well-known/mta-sts.txt`
5. Use online tools such as [MTA-STS Validator](https://aykevl.nl/apps/mta-sts/) to validate the configuration
6. After a few days of testing, switch to "enforce" mode

## Troubleshooting

### Policy not accessible
- Verify that the A/CNAME record for mta-sts.domain.com points correctly
- Verify that the SSL certificate is valid for mta-sts.domain.com
- Check the Postal logs for errors

### DNS records not verified
- Wait for DNS propagation (can take up to 48 hours)
- Verify that the records are configured correctly in your DNS provider
- Use `dig` or `nslookup` to verify the records manually

### Emails rejected in enforce mode
- Temporarily switch back to "testing" mode
- Verify the specified MX patterns
- Check the TLS-RPT reports for error details
