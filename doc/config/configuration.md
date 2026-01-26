# Configuring Postal

Postal can be configured in two ways: using a YAML-based configuration file or through environment variables.

If you choose to use environment variables, you don't need to provide a config file. A full list of environment variables is available in the `environment-variables.md` file in this directory. 

To use a configuration file, the `POSTAL_CONFIG_FILE_PATH` environment variable will dictate where Postal will look for the config file. An example YAML file containing all available configuration is provided in the `yaml.yml` file in this directory. Remember to include the `version: 2` key/value in your configuration file.

## Development 

When developing with Postal, you can configure the application by placing a configuration file in `config/postal/postal.yml`. Alternatively, you can use environment variables by placing configuration in `.env` in the root of the application.

### Running tests

By default, tests will use the `config/postal/postal.test.yml` configuration file and the `.env.test` environment file.

## Containers

Within a container, Postal will for a config file in `/config/postal.yml` unless overriden by the `POSTAL_CONFIG_FILE_PATH` environment variable.

## Ports & Bind Addresses

The web & SMTP server listen on ports and addresses. The defaults for these can be set through configuration however, if you're running multiple instances of these on a single host you will need to specify different ports for each one.

You can use the `PORT` and `BIND_ADDRESS` environment variables to provide instance-specific values for these processes.

Additionally, `HEALTH_SERVER_PORT` and `HEALTH_SERVER_BIND_ADDRESS`  can be used to set the port/address to use for running the health server alongside other processes.

## MTA-STS Configuration

Postal supports MTA-STS (Mail Transfer Agent Strict Transport Security) for enhanced email security. MTA-STS requires serving policy files at `https://mta-sts.yourdomain.com/.well-known/mta-sts.txt`.

### Host Authorization

Rails 7 includes a `HostAuthorization` middleware that blocks requests with unauthorized `Host` headers. While Postal automatically permits hosts matching the pattern `/\Amta-sts\./i`, in some production environments you may need to explicitly allow MTA-STS domains.

### MTA_STS_DOMAINS Environment Variable

Use the `MTA_STS_DOMAINS` environment variable to specify additional domains that should be allowed for MTA-STS policy serving:

```bash
# Single domain
MTA_STS_DOMAINS="mta-sts.example.com"

# Multiple domains (comma-separated)
MTA_STS_DOMAINS="mta-sts.domain1.com,mta-sts.domain2.com,mta-sts.domain3.com"
```

**When to use:**
- When deploying on Kubernetes or other container orchestration platforms
- When using reverse proxies that may interfere with host header matching
- When the automatic regex matching `/\Amta-sts\./i` doesn't work in your environment

**Security Note:** Only add domains that you control and need for MTA-STS. The `/.well-known/mta-sts.txt` endpoint must be publicly accessible (no authentication required) as per RFC 8461.

For detailed MTA-STS setup instructions, see:
- `doc/MTA-STS-SETUP-GUIDE.md` - Complete setup guide
- `doc/MTA-STS-KUBERNETES.md` - Kubernetes-specific configuration
- `doc/MTA-STS-TROUBLESHOOTING-403.md` - Troubleshooting HTTP 403 errors

## MX Rate Limiting Configuration

Postal includes a comprehensive MX rate limiting system that automatically detects and responds to rate limiting from remote mail servers.

For detailed configuration options and examples, see:
- `doc/MX_RATE_LIMITING_CONFIGURATION.md` - Complete MX rate limiting configuration guide
- `doc/MX_RATE_LIMITING_SPECIFICATION.md` - Technical specification and algorithm details

## Legacy configuration

Legacy configuration files from Postal v1 and v2 are still supported. If you wish to use a new configuration option that is not available in the legacy format, you will need to upgrade the file to version 2.
