# Complete MTA-STS Setup for Postal

This guide helps you fully configure MTA-STS for your domains in Postal.

## What is MTA-STS?

MTA-STS (Mail Transfer Agent Strict Transport Security) is an email security standard that:
- Forces the use of TLS for email connections
- Prevents man-in-the-middle attacks
- Specifies which mail servers are authorized for the domain

## Required Components

### 1. Rails Configuration ✅
Already configured in Postal:
- MTA-STS controller to serve policies
- Domain model with MTA-STS support
- Public routes for `/.well-known/mta-sts.txt`

### 2. DNS Records
You need to configure these DNS records:

```dns
; MTA-STS record (required)
_mta-sts.example.com.  IN  TXT  "v=STSv1; id=<policy-id>"

; A record for the mta-sts subdomain (required)
mta-sts.example.com.   IN  A    123.456.789.0

; TLS-RPT record (optional but recommended)
_smtp._tls.example.com. IN TXT "v=TLSRPTv1; rua=mailto:tls-reports@example.com"
```

### 3. SSL Certificate
You need a valid SSL certificate for `mta-sts.example.com`

**Option A: Wildcard Certificate** (recommended)
```bash
certbot certonly --dns-cloudflare -d "*.example.com" -d "example.com"
```

**Option B: Specific Certificate**
```bash
certbot certonly --nginx -d "mta-sts.example.com"
```

### 4. Reverse Proxy (Nginx)
Configure nginx to serve the MTA-STS endpoint publicly.

**IMPORTANT:** The `/.well-known/mta-sts.txt` endpoint **MUST** be public (no authentication).

See: `doc/MTA-STS-NGINX-CONFIG.md` for configuration examples.

## Step-by-Step Setup Procedure

### Step 1: Enable MTA-STS for the domain in Postal

1. Log in to the Postal web interface
2. Go to your server → Domains
3. Select the domain
4. Go to the "Security Settings" section
5. Enable MTA-STS:
   - **Enable MTA-STS:** Yes
   - **Mode:** `testing` (to start)
   - **Max Age:** `86400` (24 hours)
   - **MX Patterns:** Leave empty to use Postal defaults

### Step 2: Get the DNS values

After enabling MTA-STS, Postal will show you the DNS records to configure:

```
_mta-sts.example.com.  IN  TXT  "v=STSv1; id=abc123def456"
```

The `policy-id` (abc123def456) changes automatically when you modify the MTA-STS configuration.

### Step 3: Configure DNS

Add the DNS records in your provider:

1. **_mta-sts record (TXT):**
   - Name: `_mta-sts`
   - Type: `TXT`
   - Value: `v=STSv1; id=<your-policy-id>`

2. **mta-sts record (A):**
   - Name: `mta-sts`
   - Type: `A`
   - Value: `<your-postal-server-IP>`

3. **_smtp._tls record (TXT) - Optional:**
   - Name: `_smtp._tls`
   - Type: `TXT`
   - Value: `v=TLSRPTv1; rua=mailto:tls-reports@example.com`

Wait for DNS propagation (can take up to 24-48 hours).

### Step 4: Configure Nginx

**If you don't have Nginx configured**, follow `doc/MTA-STS-NGINX-CONFIG.md`

**If you already have Nginx**, make sure that:
1. There is a server block for `mta-sts.*`
2. Valid SSL certificate
3. The `/.well-known/mta-sts.txt` endpoint is **public** (no auth_basic)

Minimal configuration:

```nginx
server {
    listen 443 ssl http2;
    server_name mta-sts.*;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location = /.well-known/mta-sts.txt {
        auth_basic off;  # No authentication!
        proxy_pass http://postal:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Reload nginx:
```bash
nginx -t && systemctl reload nginx
```

### Step 5: Verify the configuration

#### 5.1 DNS Test
```bash
# Verify MTA-STS record
dig +short TXT _mta-sts.example.com
# Expected output: "v=STSv1; id=abc123def456"

# Verify A record
dig +short mta-sts.example.com
# Expected output: 123.456.789.0
```

#### 5.2 HTTPS Test
```bash
# Test MTA-STS endpoint
curl -v https://mta-sts.example.com/.well-known/mta-sts.txt

# Expected output:
# HTTP/2 200
# content-type: text/plain; charset=utf-8
#
# version: STSv1
# mode: testing
# mx: *.mx.example.com
# max_age: 86400
```

#### 5.3 Test from Postal UI
1. Go to Domains → Your domain → Security Settings
2. Click "Check MTA-STS Policy"
3. You should see: ✅ "Policy file is accessible and valid"

**If you receive a 403 error**, see `doc/MTA-STS-TROUBLESHOOTING-403.md`

### Step 6: Switch to "enforce" mode

After verifying that everything works in "testing" mode for at least 1-2 weeks:

1. Go to Postal UI → Domains → Security Settings
2. Change **Mode** from `testing` to `enforce`
3. Save
4. The DNS `policy-id` will change automatically
5. Update the `_mta-sts` DNS record with the new ID

## Testing with External Tools

### Online MTA-STS Validator
```
https://aykevl.nl/apps/mta-sts/
```

Enter your domain to verify:
- _mta-sts DNS record
- Policy file accessibility
- SSL certificate
- Policy validity

### Google Postmaster Tools
If you send emails to Gmail, monitor TLS reports at:
```
https://postmaster.google.com/
```

## MTA-STS Modes

### Testing (recommended to start)
```
mode: testing
```
- Mail servers verify the policy but **do not** block emails if it fails
- Used to test the configuration
- TLS reports show any issues
- **Recommended for the first 1-2 weeks**

### Enforce (production)
```
mode: enforce
```
- Mail servers **must** respect the policy
- Emails are rejected if secure delivery fails
- Only use after testing with `testing`

### None (disabled)
```
mode: none
```
- Policy published but not enforced
- Equivalent to MTA-STS disabled

## Max Age

Recommendations:

| Mode | Max Age | Description |
|------|---------|-------------|
| Testing  | 86400 (1 day) | For initial testing |
| Enforce  | 604800 (7 days) | For stable production |
| Enforce  | 31536000 (1 year) | For very stable configurations |

**Warning:** A high max_age means mail servers will cache the policy for longer. If you need to make changes, it may take days/weeks before all servers update.

## MX Patterns

### Default (leave empty)
Postal automatically uses its configured MX servers from `config/postal.yml`:
```
mx: *.mx.postal.example.com
```

### Custom
You can specify custom patterns (one per line):
```
*.mx1.example.com
*.mx2.example.com
mail.example.com
```

## Troubleshooting

### Problem: HTTP 403 when verifying the policy
**Solution:** See `doc/MTA-STS-TROUBLESHOOTING-403.md`

### Problem: DNS is not propagating
```bash
# Force DNS refresh
dig @8.8.8.8 +short TXT _mta-sts.example.com
```

### Problem: Invalid SSL certificate
```bash
# Verify certificate
openssl s_client -connect mta-sts.example.com:443 \
  -servername mta-sts.example.com | grep -A 2 "Verify return code"
```

### Problem: The policy is not being served
```bash
# Local test (bypass nginx)
ruby script/test_mta_sts_endpoint.rb example.com
```

## Monitoring

### Rails Logs
```bash
tail -f log/production.log | grep -i mta-sts
```

Normal output:
```
MTA-STS policy request - Host: mta-sts.example.com, Extracted domain: example.com
MTA-STS policy served successfully for domain: example.com
```

### TLS-RPT Reports
If you have configured TLS-RPT, you will receive daily emails with statistics:
- Number of successful TLS connections
- Certificate validation failures
- Other connection issues

## Security

### Best Practices
1. ✅ Always use valid SSL certificates (Let's Encrypt is fine)
2. ✅ Start with `testing` mode, switch to `enforce` after testing
3. ✅ Monitor TLS-RPT reports to identify issues
4. ✅ Use conservative max_age values (1 week) until you are confident
5. ✅ Never publish credentials in MX patterns

### What NOT to Do
1. ❌ Don't use `enforce` without testing with `testing` first
2. ❌ Don't use very high max_age values (>1 year) if your infrastructure changes often
3. ❌ Don't forget to update DNS when you change the policy
4. ❌ Don't use self-signed certificates in production
5. ❌ Don't protect `/.well-known/mta-sts.txt` with authentication

## References

- [RFC 8461 - MTA-STS](https://tools.ietf.org/html/rfc8461)
- [RFC 8460 - TLS-RPT](https://tools.ietf.org/html/rfc8460)
- [Postal Implementation Documentation](doc/MTA-STS-IMPLEMENTATION-SUMMARY.md)
- [Nginx Configuration](doc/MTA-STS-NGINX-CONFIG.md)
- [Troubleshooting 403](doc/MTA-STS-TROUBLESHOOTING-403.md)
