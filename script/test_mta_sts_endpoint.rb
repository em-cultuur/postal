#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to test the MTA-STS endpoint locally
# Usage: ruby script/test_mta_sts_endpoint.rb [domain_name]

require_relative '../config/environment'

domain_name = ARGV[0] || 'nurtigo.io'

puts "=" * 80
puts "Test MTA-STS Endpoint for #{domain_name}"
puts "=" * 80
puts

# Find the domain in the database
domain = Domain.verified.where(mta_sts_enabled: true)
               .where("LOWER(name) = ?", domain_name.downcase)
               .first

unless domain
  puts "❌ Domain not found or MTA-STS not enabled"
  puts
  puts "Verify that:"
  puts "  1. The domain '#{domain_name}' exists in the database"
  puts "  2. The domain is verified (verified_at not NULL)"
  puts "  3. MTA-STS is enabled (mta_sts_enabled = true)"
  puts

  # Show information about the domain if it exists
  any_domain = Domain.where("LOWER(name) = ?", domain_name.downcase).first
  if any_domain
    puts "Domain found but with these properties:"
    puts "  - Verified: #{any_domain.verified? ? '✅' : '❌'}"
    puts "  - MTA-STS enabled: #{any_domain.mta_sts_enabled ? '✅' : '❌'}"
  else
    puts "No domain found with name '#{domain_name}'"
    puts
    puts "Available domains:"
    Domain.all.each do |d|
      puts "  - #{d.name} (verified: #{d.verified?}, MTA-STS: #{d.mta_sts_enabled})"
    end
  end

  exit 1
end

puts "✅ Domain found: #{domain.name}"
puts "   - Verified: #{domain.verified_at}"
puts "   - MTA-STS Mode: #{domain.mta_sts_mode}"
puts "   - MTA-STS Max Age: #{domain.mta_sts_max_age}"
puts

# Test policy generation
puts "-" * 80
puts "Policy Content:"
puts "-" * 80
policy_content = domain.mta_sts_policy_content
if policy_content
  puts policy_content
else
  puts "❌ No policy generated!"
end
puts

# Simulate an HTTP request to the controller
puts "-" * 80
puts "HTTP request test (simulated):"
puts "-" * 80

require 'rack/mock'

# Test with mta-sts prefix
test_hosts = [
  "mta-sts.#{domain_name}",
  domain_name
]

test_hosts.each do |host|
  puts "\nTest with Host: #{host}"
  env = Rack::MockRequest.env_for(
    "https://#{host}/.well-known/mta-sts.txt",
    'HTTP_HOST' => host
  )

  status, headers, body = Rails.application.call(env)

  puts "  Status: #{status}"
  puts "  Content-Type: #{headers['Content-Type']}"
  puts "  Cache-Control: #{headers['Cache-Control']}"

  body_content = if body.respond_to?(:body)
                   body.body
                 elsif body.is_a?(Array)
                   body.join
                 else
                   body.to_s
                 end

  if status == 200
    puts "  ✅ Success!"
    puts "  Body preview: #{body_content[0..100]}..."
  else
    puts "  ❌ Error!"
    puts "  Body: #{body_content}"
  end
end

puts
puts "=" * 80
puts "Test completed!"
puts "=" * 80
puts
puts "NOTE: If the local test works but the UI check fails with 403,"
puts "      the problem is in your reverse proxy (nginx/apache/caddy)."
puts "      See doc/MTA-STS-PUBLIC-ACCESS.md for configuration."
puts
