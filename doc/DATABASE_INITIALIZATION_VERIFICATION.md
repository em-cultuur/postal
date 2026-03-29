# Database Initialization Verification

## Date: November 10, 2025

## Summary

This document verifies that all configured migrations are executed during the Postal database initialization.

## Initialization Process

### 1. Initialization Command

The main command to initialize the database is:

```bash
bin/postal initialize
```

This command internally executes:
```bash
bundle exec rake db:create postal:update
```

### 2. `postal:update` Task

The `postal:update` task (defined in `lib/tasks/postal.rake`) implements an intelligent logic:

```ruby
desc "Update the database"
task update: :environment do
  mysql = ActiveRecord::Base.connection
  if mysql.table_exists?("schema_migrations") &&
     mysql.select_all("select * from schema_migrations").any?
    puts "Database schema is already loaded. Running migrations with db:migrate"
    Rake::Task["db:migrate"].invoke
  else
    puts "No schema migrations exist. Loading schema with db:schema:load"
    Rake::Task["db:schema:load"].invoke
  end
end
```

**Behavior:**
- If the `schema_migrations` table exists and has records → runs `db:migrate` (applies only missing migrations)
- Otherwise → runs `db:schema:load` (loads the entire schema from `db/schema.rb`)

### 3. Available Migrations

The migrations present in the `db/migrate/` directory are (in chronological order):

1. `20161003195209_create_authie_sessions.authie.rb` - Creates Authie sessions
2. `20161003195210_add_indexes_to_authie_sessions.authie.rb` - Adds indexes
3. `20161003195211_add_parent_id_to_authie_sessions.authie.rb` - Parent ID for sessions
4. `20161003195212_add_two_factor_auth_fields_to_authie.authie.rb` - 2FA fields
5. `20170418200606_initial_schema.rb` - Complete initial schema
6. `20170421195414_add_token_hashes_to_authie_sessions.authie.rb` - Token hash
7. `20170421195415_add_index_to_token_hashes_on_authie_sessions.authie.rb` - Token hash index
8. `20170428153353_remove_type_from_ip_pools.rb` - Removes type from IP pools
9. `20180216114344_add_host_to_authie_sessions.authie.rb` - Host field
10. `20200717083943_add_uuid_to_credentials.rb` - UUID for credentials
11. `20210727210551_add_priority_to_ip_addresses.rb` - IP addresses priority
12. `20240206173036_add_privacy_mode_to_servers.rb` - Privacy mode
13. `20240213165450_create_worker_roles.rb` - Worker roles
14. `20240213171830_create_scheduled_tasks.rb` - Scheduled tasks
15. `20240214132253_add_lock_fields_to_webhook_requests.rb` - Webhook lock fields
16. `20240223141500_add_two_factor_required_to_sessions.authie.rb` - 2FA required
17. `20240223141501_add_countries_to_authie_sessions.authie.rb` - Countries for sessions
18. `20240311205229_add_oidc_fields_to_user.rb` - OIDC fields
19. `20250716102600_add_truemail_enabled_to_servers.rb` - **Truemail integration**
20. `20250915065902_add_priority_to_server.rb` - Server priority
21. `20251107000001_add_mta_sts_and_tls_rpt_to_domains.rb` - MTA-STS and TLS-RPT
22. `20251109101656_add_dmarc_fields_to_domains.rb` - **DMARC fields**

### 4. Current Schema Version

The `db/schema.rb` file now correctly reports:

```ruby
ActiveRecord::Schema[7.1].define(version: 2025_11_09_101656) do
```

This is the version of the latest available migration (`20251109101656`).

### 5. Verification of Applied Changes

#### DMARC Migration (20251109101656)
The migration adds to the `domains` table:
- `dmarc_status` (string)
- `dmarc_error` (string)

**Status:** ✅ **APPLIED** - Fields are present in schema.rb

#### Truemail Migration (20250716102600)
The migration adds to the `servers` table:
- `truemail_enabled` (boolean, default: false)

**Status:** ✅ **APPLIED** - Field is present in schema.rb

#### Server Priority Migration (20250915065902)
The migration adds to the `servers` table:
- `priority` (integer, limit: 2, default: 0, unsigned: true)

**Status:** ✅ **APPLIED** - Field is present in schema.rb

#### MTA-STS and TLS-RPT Migration (20251107000001)
The migration adds to the `domains` table:
- `mta_sts_enabled` (boolean, default: false)
- `mta_sts_mode` (string, limit: 20, default: "testing")
- `mta_sts_max_age` (integer, default: 86400)
- `mta_sts_mx_patterns` (text)
- `mta_sts_status` (string)
- `mta_sts_error` (string)
- `tls_rpt_enabled` (boolean, default: false)
- `tls_rpt_email` (string)
- `tls_rpt_status` (string)
- `tls_rpt_error` (string)

**Status:** ✅ **APPLIED** - All fields are present in schema.rb

## Conclusions

✅ **VERIFICATION PASSED**: All configured migrations have been correctly integrated into the database schema.

### New Database Initialization Process

When a new database is initialized:

1. **Command:** `bin/postal initialize`
2. **Execution:** `rake db:create postal:update`
3. **Behavior:** Since `schema_migrations` does not exist, `db:schema:load` is executed
4. **Result:** The database is created with the complete schema from `db/schema.rb` (version 2025_11_09_101656)

### Existing Database Update Process

When an existing database is updated:

1. **Command:** `bin/postal update` or `bin/postal upgrade`
2. **Execution:** `rake postal:update`
3. **Behavior:** Since `schema_migrations` exists with records, `db:migrate` is executed
4. **Result:** Only the migrations not yet applied are executed

### Message Database Migrations

The `db:migrate` task has been extended to also run migrations on the message databases:

```ruby
Rake::Task["db:migrate"].enhance do
  Rake::Task["postal:migrate_message_databases"].invoke
end
```

This ensures that the databases specific to each server are also updated.

## Recommendations

1. ✅ **NEVER directly modify** `db/schema.rb` - this file is auto-generated
2. ✅ **Always create migrations** for database changes using `rails generate migration`
3. ✅ **Test migrations** in the development environment before deploying
4. ✅ **Maintain chronological order** of migration timestamps
5. ✅ **Include up/down methods** or use `change` for reversible migrations

## Truemail Integration

The migration `20250716102600_add_truemail_enabled_to_servers.rb` has been correctly applied and allows:

- Enabling/disabling Truemail per individual server via the `truemail_enabled` field
- Integrating with Truemail-Rack via API to validate email addresses before sending

This integration follows the same pattern as SpamAssassin and ClamAV as requested in the instructions.
