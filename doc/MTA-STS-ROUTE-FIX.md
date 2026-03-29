# Fix for the MTA-STS Route .well-known/mta-sts.txt

## Problem Resolved

The `.well-known/mta-sts.txt` route was not working correctly because:

1. **Host Authorization**: Rails was blocking requests from hosts with the `mta-sts.*` pattern
2. **Authentication**: The controller required login even for public endpoints
3. **Authie Exceptions**: Session exceptions were not being handled correctly for public endpoints
4. **CSRF Protection**: The CSRF token was causing 403 errors

## Changes Made

### 1. MTA-STS Controller (`app/controllers/mta_sts_controller.rb`)

**Main changes:**
- ✅ Removed `skip_before_action :set_browser_id` (method no longer exists)
- ✅ Added `protect_from_forgery with: :null_session` for public endpoints
- ✅ Added `rescue_from` for Authie exceptions with a no-op handler
- ✅ Improved logging for debugging
- ✅ Added case-insensitive search for domain names

**Functionality:**
- Public endpoint accessible without authentication
- Handles requests from both `mta-sts.example.com` and `example.com`
- Detailed logging for troubleshooting
- Case-insensitive domain search

### 2. Well Known Controller (`app/controllers/well_known_controller.rb`)

**Changes:**
- ✅ Removed `skip_before_action :set_browser_id` (no longer exists)
- ✅ Added `protect_from_forgery with: :null_session` for consistency

### 3. Legacy API Base Controller (`app/controllers/legacy_api/base_controller.rb`)

**Changes:**
- ✅ Removed `skip_before_action :set_browser_id` (no longer exists)

### 4. Application Configuration (`config/application.rb`)

**Changes:**
- ✅ Added pattern to authorize `mta-sts.*` hosts
- ✅ Pattern: `/\Amta-sts\./i` to accept all mta-sts subdomains

```ruby
config.hosts << Postal::Config.postal.web_hostname
# Allow mta-sts subdomains for MTA-STS policy serving
config.hosts << /\Amta-sts\./i
```

### 5. Test Configuration (`config/environments/test.rb`)

**Changes:**
- ✅ Added `config.hosts << /.*/` to accept any host in tests
- ✅ Simplifies testing without needing to configure specific hosts

### 6. Test Specs (`spec/controllers/mta_sts_controller_spec.rb`)

**Created new test file with:**
- ✅ Test for domains with MTA-STS enabled
- ✅ Test for custom MX patterns
- ✅ Test for unverified domains
- ✅ Test for domains with MTA-STS disabled
- ✅ Test for non-existent domains
- ✅ Test for requests without mta-sts prefix
- ✅ Test for case-insensitive domain names
- ✅ All tests pass ✅

## How It Works Now

### 1. Request from `mta-sts.example.com`

```
GET https://mta-sts.example.com/.well-known/mta-sts.txt
Host: mta-sts.example.com
```

**Flow:**
1. Host Authorization: `mta-sts.example.com` matches the pattern `/\Amta-sts\./i` ✅
2. Controller removes the `mta-sts.` prefix → `example.com`
3. Searches `Domain.verified.where(mta_sts_enabled: true).where("LOWER(name) = ?", "example.com")`
4. If found, returns `domain.mta_sts_policy_content`
5. Response: 200 OK with `Content-Type: text/plain; charset=utf-8`

### 2. Request from main domain

```
GET https://example.com/.well-known/mta-sts.txt
Host: example.com
```

**Flow:**
1. Host Authorization: `example.com` is already authorized ✅
2. Controller uses `example.com` directly
3. Searches for the domain in the database
4. Returns policy if found

### 3. Error Cases

**404 Not Found when:**
- Domain does not exist in the database
- Domain is not verified (`verified_at IS NULL`)
- MTA-STS is not enabled (`mta_sts_enabled = false`)
- Policy is not configured (`mta_sts_policy_content` is empty)

## Tests

Run the tests with:

```bash
bundle exec rspec spec/controllers/mta_sts_controller_spec.rb --format documentation
```

**Expected result:**
```
MTA-STS Policy
  GET /.well-known/mta-sts.txt
    when domain has MTA-STS enabled
      returns the MTA-STS policy
      sets the correct cache control header
    when domain has MTA-STS enabled with custom MX patterns
      includes custom MX patterns in the policy
    when domain is not verified
      returns 404 not found
    when domain has MTA-STS disabled
      returns 404 not found
    when domain does not exist
      returns 404 not found
    when host is the main domain without mta-sts prefix
      returns the MTA-STS policy
    when domain name is case-insensitive
      returns the MTA-STS policy

8 examples, 0 failures
```

## Required DNS Configuration

To correctly serve MTA-STS policies, configure:

```
# A or CNAME record for mta-sts subdomain
mta-sts.example.com.    A    <POSTAL-SERVER-IP>
# or
mta-sts.example.com.    CNAME    postal.example.com.

# TXT record for MTA-STS
_mta-sts.example.com.    TXT    "v=STSv1; id=<policy-id>;"
```

## Logging

The controller now logs all requests:

```
MTA-STS policy request - Host: mta-sts.example.com, Extracted domain: example.com
MTA-STS policy served successfully for domain: example.com
```

Logged errors:
```
MTA-STS policy request failed - Invalid domain from host: invalid
MTA-STS policy request failed - Domain not found or not enabled: nonexistent.com
MTA-STS policy request failed - No policy content for domain: example.com
```

## Important Notes

1. **Public Endpoint**: Does not require authentication - accessible to everyone
2. **Case Insensitive**: Accepts `EXAMPLE.COM`, `example.com`, `Example.Com`
3. **Cache Control**: Respects the domain's `mta_sts_max_age` (default: 86400)
4. **HTTPS Required**: In production MTA-STS requires HTTPS with a valid certificate
5. **Standard Compliance**: Implementation compliant with RFC 8461

## References

- RFC 8461: SMTP MTA Strict Transport Security (MTA-STS)
- [MTA-STS Documentation](./MTA-STS-AND-TLS-RPT.md)
- [MTA-STS Implementation Summary](./MTA-STS-IMPLEMENTATION-SUMMARY.md)
