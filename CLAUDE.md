# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Postal is a self-hosted open-source mail server platform built with Ruby on Rails 7.1.5.2. It provides SMTP sending/receiving, a web dashboard, message tracking, webhooks, and IP pool management — functionally similar to SendGrid or Mailgun.

## This Is a Fork (em-cultuur/postal)

This repo is a fork of [postalserver/postal](https://github.com/postalserver/postal). It exists only to carry the **message-token-in-return-path for bounce matching** work (upstream PR [#2855](https://github.com/postalserver/postal/pull/2855) "Add message token to SMTP FROM" + companion PR #3036 bounce-matching-by-tag). We do **not** maintain an independent version line.

### Versioning rule

Track the upstream **released** version and append an `-em` suffix. Example: upstream `3.3.7` → fork `3.3.7-em`. Base on the upstream release **tag**, not `main` HEAD, so the number stays exact. Tags have no `v` prefix (`include-v-in-tag: false`).

### Remotes

- `origin` → `https://github.com/em-cultuur/postal.git` (this fork)
- `upstream` → `https://github.com/postalserver/postal.git`

### Sync workflow (each time upstream cuts a new release, e.g. 3.3.8)

1. `git fetch --tags upstream`
2. Branch from the upstream release tag: `git branch -f rebuild-<ver>-em <ver> && git checkout rebuild-<ver>-em`
3. Keep the fork's `.github/workflows/ci.yml` — its only diff from upstream is the image name `ghcr.io/em-cultuur/postal` (6 occurrences): `git checkout main -- .github/workflows/ci.yml && git commit -m "ci: use em-cultuur image registry"`
4. Cherry-pick the two PR commits (SMTP FROM token, then bounce-matching-by-tag). They apply cleanly; only `config_schema.rb` / `doc/config/yaml.yml` may need a trivial merge.
5. Force the version: `git commit --allow-empty -m "chore: release <ver>-em" -m "Release-As: <ver>-em"`
6. Point `main` at it and force-push: `git branch -f main rebuild-<ver>-em && git push --force-with-lease origin main`

### How the pullable image is produced

release-please is kept **only** to drive the release. After the force-push it opens a "release `<ver>-em`" PR; **merging that PR** creates the git tag + GitHub Release and sets `release_created`, which triggers the `publish-image` CI job. That job builds `target: full` and pushes:

- `ghcr.io/em-cultuur/postal:<ver>-em`
- `ghcr.io/em-cultuur/postal:stable`

The `release-branch` job also pushes `:latest` on every `main` push. VERSION is injected at Docker build via `ARG VERSION`. Pull with:

```bash
docker pull ghcr.io/em-cultuur/postal:<ver>-em   # docker login ghcr.io first if the package is private
```

### Runtime note

The bounce-matching half only takes effect when `postal.use_message_tags_for_bounces` is set `true` in the Postal config (default `false`). Without it, bounce matching falls back to scanning the `X-Postal-MsgID` header only.

## Commands

```bash
# Install dependencies
bundle install

# Run all components together (web, SMTP server, worker)
bin/dev

# Run individual components
bin/postal web-server
bin/postal smtp-server
bin/postal worker

# Database setup
bin/postal initialize      # Create databases and run migrations
bin/postal make-user       # Create first admin user

# Testing
bundle exec rspec                        # Full test suite
bundle exec rspec spec/path/to/spec.rb   # Single file
bundle exec rspec spec/path/to/spec.rb:42 # Single example

# Linting
bundle exec rubocop
bundle exec rubocop -a  # Auto-correct

# Assets
bundle exec rake assets:precompile
```

## Architecture

Postal runs as **three separate processes** that must all be running for the full system to work:

1. **Web Server** (`script/web_server.rb`) — Rails app serving the dashboard UI and legacy API
2. **SMTP Server** (`script/smtp_server.rb`, `app/lib/smtp_server/`) — Handles inbound/outbound SMTP connections using a NIO-based event loop
3. **Worker** (`script/worker.rb`, `app/lib/worker/`) — Background job processor for queued messages, webhook delivery, and scheduled tasks

### Data Model

The core multi-tenant hierarchy:

```
Organization
├── Users
└── Server (mail server instance, has its own message DB)
    ├── Domains (with DKIM/SPF verification)
    ├── Credentials (API tokens)
    ├── Routes → Endpoints (HTTP, SMTP, or Address)
    ├── Messages (stored in a per-server message database)
    ├── QueuedMessages
    └── Webhooks + WebhookRequests
```

Each `Server` has its own **separate MySQL database** for message storage, managed via `app/lib/postal/message_db/`. The main database holds configuration; message content lives in per-server databases.

### Key Library Locations

- `app/lib/postal/` — Core business logic (message processing, SMTP client, DNS resolver, config system, signer for DKIM)
- `app/lib/smtp_server/` — Inbound SMTP server implementation
- `app/lib/worker/` — Background worker and scheduled task definitions
- `lib/postal/` — Lower-level utilities

### Configuration

Config is loaded from `config/postal/postal.yml` (and `postal.test.yml` for tests). Every option can be overridden via `POSTAL_*` environment variables. Schema is defined in `lib/postal/config_schema.rb`.

For local development, copy `config/examples/development.yml` → `config/postal/postal.yml` and set MySQL credentials. Generate a signing key with `openssl genrsa -out config/postal/signing.key 2048`.

### Testing Setup

- RSpec with FactoryBot (`spec/factories/`)
- DatabaseCleaner for isolation (test databases are truncated between tests)
- WebMock for HTTP stubbing, Timecop for time control
- Test config needs `config/postal/postal.test.yml`

**Running tests requires Docker** — the local Ruby version typically doesn't match the project requirement (bundler 2.7.2, Ruby 3.x). Run tests the same way CI does:

```bash
# Build the CI image (only needed once or after Gemfile changes)
docker build --target=ci -t postal-ci .

# Run full test suite
docker compose run --rm web bundle exec rspec

# Run a single spec file
docker compose run --rm web bundle exec rspec spec/lib/smtp_server/client/auth_spec.rb

# Run linter
docker compose run --rm web bundle exec rubocop
```

### CI

GitHub Actions (`.github/workflows/ci.yml`) builds a Docker image with `--target=ci`, runs `bundle exec rspec` inside it. The `docker-compose.yml` in the repo root is used for CI (provides MariaDB). Release-please manages semantic versioning; releases are published to `ghcr.io`.

### SMTP Server Architecture

`app/lib/smtp_server/server.rb` — infrastructure layer. Owns the nio4r event loop, TCP listeners, and TLS socket wrapping. For each incoming connection it creates a `Client` instance and passes lines to it.

`app/lib/smtp_server/client.rb` — protocol state machine. Processes one SMTP command at a time, transitions states, returns response strings.

**Three listening ports** (587 and 465 open automatically when `tls_enabled` is true in config):

| Port | Mode | `submission:` flag | `tls:` flag | Mandatory TLS | Mandatory auth |
|------|------|--------------------|-------------|---------------|----------------|
| 25   | Relay SMTP | false | false | No | No |
| 587  | Submission (RFC 6409) | **true** | false | Yes (STARTTLS) | Yes |
| 465  | SMTPS / implicit TLS (RFC 8314) | false | **true** | Yes (already TLS at connect) | No |

The `submission:` flag on `Client` enforces that AUTH and MAIL FROM are rejected with `530 5.7.0` until STARTTLS has been completed, and that MAIL FROM / RCPT TO require a valid credential (`530 5.7.1`).

The `tls:` flag marks a connection as already encrypted (port 465 wraps the socket in `SSLSocket` at accept time, before the SMTP dialog starts). It also suppresses STARTTLS advertisement in EHLO and returns `503 TLS already active` if STARTTLS is attempted.

**Port 465 banner deferral**: the 220 welcome banner cannot be sent until the async TLS handshake completes. `client.pending_welcome = true` is set at accept time; the event loop sends the banner and clears the flag once `accept_nonblock` succeeds.

Config options (in `smtp_server` group, `lib/postal/config_schema.rb`):
- `default_submission_port` — default `587`
- `default_tls_port` — default `465`
