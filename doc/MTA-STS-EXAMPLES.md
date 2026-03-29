# Practical Examples - MTA-STS HTTPS Policy Verification

## Scenario 1: Configuration and Testing of a New Domain

### Step 1: Add the domain
```
1. Go to Postal → Organization → Server → Domains
2. Click "Add Domain"
3. Enter "example.com"
4. Verify the domain (DNS or Email)
```

### Step 2: Enable MTA-STS
```
1. Go to the domain page
2. Click "Configure MTA-STS & TLS-RPT"
3. Check "Enable MTA-STS"
4. Select "Testing" mode
5. Set Max Age: 86400 (1 day for testing)
6. Leave MX patterns empty (use defaults)
7. Click "Save Security Settings"
```

### Step 3: Configure DNS
```
1. In your DNS provider, add:

   TXT Record:
   Name: _mta-sts.example.com
   Value: v=STSv1; id=20251107abc123;

   A or CNAME Record:
   Name: mta-sts.example.com
   Value: postal.yourserver.com (or your Postal IP)
```

### Step 4: Verify Policy File
```
1. Return to the domain's "DNS Setup" page
2. In the MTA-STS section, click "Test MTA-STS Policy File"
3. You should see: "MTA-STS policy file is accessible and valid"
```

### Step 5: Complete DNS Verification
```
1. Click "Check my records are correct"
2. Postal will verify:
   - SPF Record ✓
   - DKIM Record ✓
   - MX Records ✓
   - Return Path ✓
   - MTA-STS DNS Record ✓
   - MTA-STS HTTPS Policy ✓ (NEW!)
```

## Scenario 2: Debugging SSL Error

### Problem
```
SSL certificate error for https://mta-sts.example.com/.well-known/mta-sts.txt:
certificate verify failed (unable to get local issuer certificate)
```

### Solution
```
1. Verify that the SSL certificate covers the subdomain:
   - Certificate for *.example.com (wildcard), or
   - Certificate for mta-sts.example.com (specific)

2. If using Let's Encrypt, regenerate the certificate including SAN:
   certbot certonly --webroot -w /var/www/html \
     -d example.com \
     -d mta-sts.example.com \
     -d www.example.com

3. Reload the web server (nginx/apache)

4. Retry the test in Postal
```

### Manual Certificate Verification
```bash
# Check the SSL certificate
openssl s_client -connect mta-sts.example.com:443 -servername mta-sts.example.com < /dev/null 2>/dev/null | openssl x509 -noout -text | grep DNS

# Should show:
# DNS:example.com, DNS:mta-sts.example.com, DNS:*.example.com
```

## Scenario 3: Debugging HTTP 404

### Problem
```
Policy file returned HTTP 404. Expected 200.
URL: https://mta-sts.example.com/.well-known/mta-sts.txt
```

### Diagnosis
```bash
# Manual test with curl
curl -v https://mta-sts.example.com/.well-known/mta-sts.txt

# Check the HTTP response
```

### Possible Causes

#### Cause 1: DNS does not point to Postal
```
1. Verify the DNS record:
   dig mta-sts.example.com

2. It should point to your Postal server
```

#### Cause 2: MTA-STS not enabled in Postal
```
1. Go to "Configure MTA-STS & TLS-RPT"
2. Make sure "Enable MTA-STS" is checked
3. Save the settings
```

#### Cause 3: Web server not configured
```
1. If using a reverse proxy (nginx/apache), make sure that:
   - The mta-sts.example.com domain is configured
   - .well-known requests are passed to Postal

Nginx example:
server {
    server_name mta-sts.example.com;

    location /.well-known/mta-sts.txt {
        proxy_pass http://postal_backend;
        proxy_set_header Host $host;
    }
}
```

## Scenario 4: Policy with Custom MX Patterns

### Configuration
```
1. Go to "Configure MTA-STS & TLS-RPT"
2. In "MX Patterns", enter (one per line):
   mx1.example.com
   mx2.example.com
   backup-mx.example.com
3. Save
```

### Content Verification
```bash
# Check the policy content
curl https://mta-sts.example.com/.well-known/mta-sts.txt

# Expected output:
version: STSv1
mode: testing
mx: mx1.example.com
mx: mx2.example.com
mx: backup-mx.example.com
max_age: 86400
```

## Scenario 5: Switching from Testing to Enforce

### Recommendations
```
1. Use "testing" mode for at least 7 days
2. Monitor TLS-RPT reports for errors
3. Gradually increase the max_age:
   - Day 1-7: 86400 (1 day)
   - Day 8-14: 604800 (7 days)
   - Day 15+: 2592000 (30 days) in enforce mode
```

### Procedure
```
1. Go to "Configure MTA-STS & TLS-RPT"
2. Change mode from "testing" to "enforce"
3. Increase max_age to 604800
4. Save
5. The _mta-sts DNS record will automatically update with a new ID
6. Click "Test MTA-STS Policy File" to confirm
```

## Scenario 6: API Testing

### Manual Test via cURL
```bash
# Login and get session cookie
curl -c cookies.txt -X POST https://postal.example.com/login \
  -d "email_address=admin@example.com" \
  -d "password=yourpassword"

# Test policy file
curl -b cookies.txt -X POST \
  https://postal.example.com/org/myorg/servers/myserver/domains/DOMAIN-UUID/check_mta_sts_policy \
  -H "Accept: application/json"

# Expected output (success):
{
  "success": true,
  "message": "MTA-STS policy file is accessible and valid at https://mta-sts.example.com/.well-known/mta-sts.txt",
  "url": "https://mta-sts.example.com/.well-known/mta-sts.txt"
}

# Expected output (error):
{
  "success": false,
  "error": "Policy file returned HTTP 404. Expected 200. URL: https://mta-sts.example.com/.well-known/mta-sts.txt",
  "url": "https://mta-sts.example.com/.well-known/mta-sts.txt"
}
```

## Scenario 7: Monitoring and Logging

### Request Logs
```bash
# Tail Postal logs
tail -f log/development.log | grep -i mta-sts

# Example log for verification request:
Started POST "/org/myorg/servers/myserver/domains/abc123/check_mta_sts_policy"
Processing by DomainsController#check_mta_sts_policy
Completed 200 OK
```

### Verification from Rails Command Line
```bash
# Enter the Rails console
bundle exec rails console

# Find the domain
domain = Domain.find_by(name: 'example.com')

# Manual verification
result = domain.check_mta_sts_policy_file
puts result.inspect

# Output:
# {:success=>true} or
# {:success=>false, :error=>"..."}

# Complete DNS verification (includes HTTPS)
domain.check_mta_sts_record
puts domain.mta_sts_status  # "OK", "Invalid", "Missing"
puts domain.mta_sts_error    # nil or error message
```

## Scenario 8: Troubleshooting Timeout

### Problem
```
Timeout while fetching policy file from https://mta-sts.example.com/.well-known/mta-sts.txt:
execution expired
```

### Diagnosis
```bash
# Manual connection test
time curl -v https://mta-sts.example.com/.well-known/mta-sts.txt

# If it takes more than 10 seconds:
# 1. Check firewall
# 2. Check server performance
# 3. Check network latency
```

### Temporary Solution (development only!)
```ruby
# In app/models/concerns/has_dns_checks.rb
# Increase timeouts (NOT recommended in production):
http.open_timeout = 30  # instead of 10
http.read_timeout = 30  # instead of 10
```

## Useful References

### Online Validators
- https://aykevl.nl/apps/mta-sts/ - Complete MTA-STS Validator
- https://mxtoolbox.com/SuperTool.aspx - Generic DNS Tool

### Useful Commands
```bash
# Verify DNS TXT record
dig TXT _mta-sts.example.com

# Verify A/CNAME record
dig mta-sts.example.com

# Test HTTPS with SSL details
curl -vvv https://mta-sts.example.com/.well-known/mta-sts.txt

# Test from Rails console
bundle exec rails console
Domain.find_by(name: 'example.com').check_mta_sts_policy_file
```
