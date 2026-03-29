# MTA-STS HTTPS Policy Verification Implementation

## Overview
The HTTPS verification functionality for the MTA-STS policy file has been added to Postal. This feature verifies that the policy file is accessible and valid via HTTPS at the URL `https://mta-sts.domain.com/.well-known/mta-sts.txt`.

## Modified Files

### 1. `app/models/concerns/has_dns_checks.rb`
**Changes:**
- `check_mta_sts_record` method extended to include HTTPS verification
- Added `check_mta_sts_policy_file` method to verify the accessibility and validity of the policy file

**Functionality:**
- HTTPS connection with SSL certificate verification
- 10-second timeout for opening and reading
- Content validation:
  - Verifies presence of `version: STSv1`
  - Verifies valid mode (testing/enforce/none)
  - Verifies max_age value
- Detailed error handling:
  - SSL errors (invalid certificate)
  - Connection timeout
  - HTTP errors (404, 500, etc.)
  - Invalid content

### 2. `app/models/domain.rb`
**Added:**
- `mta_sts_policy_url` method: returns the full policy URL

### 3. `app/controllers/domains_controller.rb`
**Added:**
- `check_mta_sts_policy` action: allows manual verification of the policy file
- Supports responses in JSON and JavaScript formats

### 4. `app/views/domains/setup.html.haml`
**Changes:**
- Added "Test MTA-STS Policy File" button for manual verification
- Added "View Policy File" link to open the file in a new tab
- Updated status message to indicate DNS + HTTPS verification

### 5. `app/views/domains/check_mta_sts_policy.js.erb`
**New file:**
- Handles the AJAX response for the manual test
- Shows success/error notifications to the user

### 6. `config/routes.rb`
**Added:**
- Route `post :check_mta_sts_policy, on: :member` for both contexts (organization and server)

### 7. `doc/MTA-STS-AND-TLS-RPT.md`
**Updated:**
- Complete documentation of the HTTPS verification functionality
- Usage examples and troubleshooting

### 8. `spec/models/mta_sts_spec.rb`
**New file:**
- RSpec tests for policy file verification
- Coverage of various scenarios (success, HTTP errors, SSL, timeout, etc.)

## How It Works

### Automatic Verification (during DNS check)
When a user clicks "Check my records are correct", the system:
1. Verifies the DNS TXT record `_mta-sts.domain.com`
2. **NEW:** Makes an HTTPS request to `https://mta-sts.domain.com/.well-known/mta-sts.txt`
3. Validates the SSL certificate
4. Verifies that the server responds with HTTP 200
5. Validates the policy file content
6. Updates the status in `mta_sts_status` and `mta_sts_error`

### Manual Verification
On the "DNS Setup" page, when MTA-STS is enabled, the user can:
1. Click "Test MTA-STS Policy File" to verify only the policy file
2. Click "View Policy File" to open the file in the browser
3. Receive immediate feedback on any issues

## Usage Example

### Via Web UI
1. Go to the domain page
2. Click "DNS Setup"
3. If MTA-STS is enabled, you will see the MTA-STS section
4. Click "Test MTA-STS Policy File" to verify
5. You will receive a green notification if everything is OK, or a red one with error details

### Via API
```bash
# Manual test of the policy file
curl -X POST \
  https://postal.example.com/org/myorg/servers/myserver/domains/UUID/check_mta_sts_policy \
  -H 'Content-Type: application/json' \
  -H 'Cookie: session=...'
```

Success response:
```json
{
  "success": true,
  "message": "MTA-STS policy file is accessible and valid at https://mta-sts.example.com/.well-known/mta-sts.txt",
  "url": "https://mta-sts.example.com/.well-known/mta-sts.txt"
}
```

Error response:
```json
{
  "success": false,
  "error": "SSL certificate error for https://mta-sts.example.com/.well-known/mta-sts.txt: certificate verify failed",
  "url": "https://mta-sts.example.com/.well-known/mta-sts.txt"
}
```

## Error Messages

### SSL Errors
```
SSL certificate error for https://mta-sts.example.com/.well-known/mta-sts.txt: certificate verify failed
```
**Cause:** The SSL certificate is not valid or does not cover the mta-sts subdomain
**Solution:** Make sure the SSL certificate covers `*.domain.com` or `mta-sts.domain.com`

### HTTP Errors
```
Policy file returned HTTP 404. Expected 200. URL: https://mta-sts.example.com/.well-known/mta-sts.txt
```
**Cause:** The policy file is not accessible at the specified URL
**Solution:** Verify that the A/CNAME record for mta-sts.domain.com points correctly and that Postal is serving the file

### Timeout Errors
```
Timeout while fetching policy file from https://mta-sts.example.com/.well-known/mta-sts.txt: execution expired
```
**Cause:** The server does not respond within 10 seconds
**Solution:** Verify that the server is reachable and there are no firewall issues

### Content Errors
```
Policy file doesn't contain 'version: STSv1'. URL: https://mta-sts.example.com/.well-known/mta-sts.txt
```
**Cause:** The policy file content is not valid
**Solution:** Verify that MTA-STS is correctly enabled in Postal and that the configuration is saved

## Testing

To test the functionality:

```bash
# Run the RSpec tests
bundle exec rspec spec/models/mta_sts_spec.rb
```

## Technical Notes

- **Timeout:** 10 seconds for opening + 10 seconds for reading
- **SSL Verification:** OpenSSL::SSL::VERIFY_PEER (certificate must be valid)
- **Caching:** Verification is NOT cached, it runs on every request
- **Performance:** HTTPS verification is only executed when check_dns is called or when manually requested

## Compatibility

- Rails 7.0+
- Ruby 2.7+
- Requires `net/http` gem (included in Ruby standard library)

## Troubleshooting

### Manual test works but DNS check fails
The `check_dns` method runs multiple checks in sequence. Verify the other DNS records (SPF, DKIM, MX) to make sure there are no other issues.

### Self-signed SSL certificate in development
During development, if you use self-signed certificates, you may want to temporarily disable SSL verification by modifying `http.verify_mode` in `has_dns_checks.rb`. **DO NOT do this in production!**

### Local network / Docker
If Postal is running in Docker or on a local network, make sure it can reach the public domain for HTTPS verification.
