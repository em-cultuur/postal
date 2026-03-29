# Copilot Instructions

## Project Context

This is a Ruby on Rails project for a mail/email service with advanced routing, tracking, and webhook functionality.

## General Guidelines

- Follow Ruby on Rails 7.0 best practices
- Use ActiveRecord for database access
- **NEVER modify the `db/schema.rb` file directly** - always use migrations
- Write automated tests for every new feature
- Keep the code clean and well documented
- Follow Rails naming conventions for models, controllers, and views
- Ensure all queries are safe from SQL injection

## Database Structure

- **Charset**: `utf8mb4` with collation `utf8mb4_general_ci` for all tables
- **Primary Keys**: Use `:integer` as the type for IDs
- **UUIDs**: Many entities use `uuid` fields for external identifiers
- **Timestamps**: Use `precision: nil` to maintain compatibility

## Main Entities

- **Organizations**: Organizations with users and servers
- **Servers**: Mail servers with modes and sending limits
- **Domains**: Verified domains with DNS/DKIM/SPF checks
- **Routes**: Message routing to endpoints
- **Endpoints**: HTTP, SMTP, and Address endpoints for delivery
- **Messages**: Message queue system (`queued_messages`)
- **Webhooks**: Notification system with automatic retry
- **Users**: Authentication with Authie sessions

## Specific Best Practices

- Always use indexes on `uuid` fields with limited length (e.g., `length: 8`)
- For status fields use enums or strings with validations
- Implement soft delete with `deleted_at` fields where appropriate
- Handle retry and locking for asynchronous systems (`locked_by`, `locked_at`)
- Use `decimal` for thresholds and percentages with defined precision
- Always include timestamps for audit trail
- For external services (SpamAssassin, ClamAV, Truemail) use robust timeout and error handling

## Security

- Never include plaintext credentials in the code
- Use token hashing for authentication (`token_hash` vs `token`)
- Implement rate limiting and spam thresholds
- Always validate input from webhooks and external APIs

## Performance

- Use appropriate indexes for frequent queries
- Implement pagination for long lists
- Consider caching for configuration data
- Monitor N+1 queries with includes/joins

## Truemail Integration

Prompt: add the development phase to integrate Truemail functionality. The integration should follow the same pattern as SpamAssassin (spamd) and ClamAV, so you need to add configuration to enable and configure it. Truemail integration is via API exposed by truemail-rack deployed in a separate Docker container. The endpoint documentation is here: https://truemail-rb.org/truemail-rack/#/endpoints. Additionally, each individual mail server should be configurable to enable or disable address verification before sending mail.

## Development Phase for Truemail Integration
- Global configuration: Add Truemail settings to the main configuration system
- Per-server configuration: Extend the Server model to allow enabling on a per-server basis
- API Client: Create a client to communicate with the Truemail API
- Pipeline integration: Add validation before sending mail
- Web interface: Add controls in the administration interface
