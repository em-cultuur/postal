# Agent Guidelines for Postal

This document provides essential information for AI coding agents working on the Postal codebase.

## Project Overview

Postal is a Ruby on Rails 7.1 mail server application for email delivery, routing, tracking, and webhooks. It's a production-grade system with custom SMTP server, background workers, and comprehensive email processing pipeline.

**Stack:** Ruby 3.4.6, Rails 7.1.5.2, MySQL/MariaDB, CoffeeScript, SCSS, Turbolinks, jQuery

## Build, Lint, and Test Commands

### Setup
```bash
bundle install                           # Install dependencies
postal initialize                        # Create database schema
postal make-user                         # Create admin user
```

### Running the Application
```bash
bin/dev                                  # Run all components (web, worker, SMTP)
bin/postal web-server                    # Run web server only
bin/postal smtp-server                   # Run SMTP server only
bin/postal worker                        # Run background worker only
bin/postal console                       # Open Rails console
```

### Testing
```bash
bundle exec rspec                        # Run all tests
bundle exec rspec spec/models            # Run all model tests
bundle exec rspec spec/models/server_spec.rb  # Run specific file
bundle exec rspec spec/models/server_spec.rb:45  # Run specific line
docker compose run --rm postal sh -c 'bundle exec rspec'  # Run in Docker
```

### Linting & Quality
```bash
bundle exec rubocop                      # Run linter
bundle exec rubocop -a                   # Auto-fix safe issues
bundle exec rubocop --autocorrect-all    # Auto-fix all issues
bundle exec annotate                     # Update model schema annotations
```

### Database
```bash
bundle exec rake db:migrate              # Run migrations
bundle exec rake db:rollback             # Rollback last migration
bundle exec rake db:reset                # Reset database
postal update                            # Upgrade DB schema (production)
```

## Code Style Guidelines

### General Principles
- Follow Rails conventions for MVC architecture
- Write comprehensive tests for all new features
- Keep code clean, readable, and maintainable
- Security first: validate inputs, use parameterized queries, avoid storing credentials in code

### String Literals
- **Always use double quotes** for strings: `"hello"` not `'hello'`
- All files must start with: `# frozen_string_literal: true`

### Formatting
- Line length: Max 200 characters (goal: reduce to 120)
- Indentation: 2 spaces (no tabs)
- Empty lines inside class/module bodies (except namespace modules):
```ruby
class MyClass

  def method_one
  end

  def method_two
  end

end
```
- No empty lines inside block bodies
- Trailing commas in multi-line arrays/hashes

### Imports & Requires
- Group requires logically (stdlib, gems, app files)
- Alphabetize within groups when practical
- Use `require` for gems, auto-loading for app classes

### Types & Variables
- No explicit type annotations (standard Ruby)
- Use meaningful variable names
- Prefer `snake_case` for methods and variables
- Prefer `SCREAMING_SNAKE_CASE` for constants
- Use `CamelCase` for classes and modules

### Naming Conventions
- Models: Singular (`User`, `Server`, `QueuedMessage`)
- Controllers: Plural (`UsersController`, `ServersController`)
- Tables: Plural, snake_case (`users`, `servers`, `queued_messages`)
- Use descriptive method names (no `get_`/`set_` prefix restrictions)
- Predicates can use `has_`, `is_`, or any descriptive name

### Arrays & Symbols
- Symbol arrays: Use bracket syntax `[:one, :two, :three]` not `%i[one two three]`
- Keep `attr_accessor`, `attr_reader`, `attr_writer` on separate lines

### Conditionals
- Assignment in conditions is allowed: `if something = get_value`
- Multi-line if statements preferred over modifier form for readability
- Assign inside condition rather than conditional assignment

### Method Definitions
- Empty methods: Use expanded form, not one-liners
```ruby
def empty_method
end
```
- Max 5 positional arguments (keyword args don't count)
- Lambda spacing: `-> (var) { block }` with space after `->`

### Error Handling
- Use service objects for complex operations with explicit error handling
- Implement retry logic for external services (webhooks, SMTP)
- Use ActiveRecord transactions for multi-step database operations
- Log errors with context (use KLogger's tagged logging)
- Raise exceptions for exceptional cases, return error objects for expected failures

### Comments & Documentation
- Use schema annotations on models (via `annotate` gem)
- No top-level class documentation required
- Write comments for complex logic only
- Code should be self-documenting via clear naming

### Testing Style
- Use RSpec with descriptive contexts and examples
- Use FactoryBot for test data (defined in `spec/factories/`)
- Use `subject(:name)` for the main test subject
- Use `let` for shared test data
- Use Timecop for time-dependent tests
- Use WebMock for external HTTP requests
- Database cleaner handles cleanup automatically
- Test file structure mirrors app structure
- Shoulda matchers for common Rails validations

Example test structure:
```ruby
# frozen_string_literal: true

require "rails_helper"

describe MyClass do
  subject(:my_object) { build(:my_object) }

  describe "#method_name" do
    context "when condition is true" do
      it "returns expected value" do
        expect(my_object.method_name).to eq("expected")
      end
    end
  end
end
```

## Database Guidelines

### Schema Management
- **NEVER modify `db/schema.rb` directly** - always use migrations
- Use `charset: "utf8mb4", collation: "utf8mb4_general_ci"` for all tables
- Primary keys: `:integer` type
- UUIDs: Add `uuid` string column with index (length: 8)
- Timestamps: Use `precision: nil` for compatibility
- Add indexes on foreign keys, UUIDs, and frequently queried fields

### Model Patterns
- Use soft deletes with `deleted_at` timestamp where appropriate
- Implement locking for async systems (`locked_by`, `locked_at`)
- Use enums or validated strings for status fields
- Use `decimal` for thresholds/percentages with defined precision
- Include timestamps for audit trails

## Key Architecture Patterns

### Directory Structure
- `app/models/` - ActiveRecord models with concerns
- `app/controllers/` - Rails controllers with concerns
- `app/services/` - Service objects for complex business logic
- `app/senders/` - Email sending implementations
- `app/scheduled_tasks/` - Scheduled background tasks
- `app/lib/` - App-specific libs (MessageDequeuer, SMTPServer, Worker)
- `lib/postal/` - Core Postal library code
- `spec/` - RSpec tests mirroring app structure

### Service Objects
- Single responsibility per service
- Initialize with required dependencies
- Implement `#call` method for main logic
- Use instance variables for state during call
- Return explicit success/failure indicators

### External Integrations
- SpamAssassin (spamd), ClamAV, Truemail configured per server
- Use timeouts for all external calls
- Implement robust error handling and fallbacks
- Configuration in `config/postal/postal.yml` or ENV vars

## Special Notes from Copilot Instructions (Italian)

- Questo è un progetto Ruby on Rails per un servizio di mail/email
- Usa sempre indici sui campi `uuid` con lunghezza limitata (es. `length: 8`)
- Per servizi esterni usa timeout e gestione errori robusta
- Non includere mai credenziali in chiaro nel codice
- Usa token hash per autenticazione (`token_hash` vs `token`)
- Implementa rate limiting e soglie spam
- Monitora query N+1 con includes/joins
- Implementa paginazione per liste lunghe (usa Kaminari gem)

## Common Gotchas

1. Don't use complexity metrics (ABC, Cyclomatic, MethodLength) - they're disabled
2. Assignment in conditions is intentional and allowed
3. Symbol proc (`&:method`) may be avoided for clarity in action blocks
4. Multiline block chains are allowed in spec files
5. Boolean symbols (`:true`, `:false`) are permitted
6. Special global vars (`$?`, `$!`) can use standard form
