# frozen_string_literal: true

# Seed script for IP Reputation Management - Sample Data
# Run with: bundle exec rails runner db/seeds/ip_reputation_sample_data.rb

puts "Creating sample data for IP Reputation Management..."

# Create IP Pools
puts "\n1. Creating IP Pools..."
pool1 = IPPool.create!(name: "Primary Pool")
pool2 = IPPool.create!(name: "Marketing Pool")
pool3 = IPPool.create!(name: "Transactional Pool")
puts "   ✓ Created 3 IP Pools"

# Create IP Addresses
puts "\n2. Creating IP Addresses..."
ips = []
ips << IPAddress.create!(ip_pool: pool1, ipv4: "192.168.1.10", hostname: "mail1.example.com", priority: 100)
ips << IPAddress.create!(ip_pool: pool1, ipv4: "192.168.1.11", hostname: "mail2.example.com", priority: 90)
ips << IPAddress.create!(ip_pool: pool2, ipv4: "192.168.2.20", hostname: "marketing1.example.com", priority: 100)
ips << IPAddress.create!(ip_pool: pool2, ipv4: "192.168.2.21", hostname: "marketing2.example.com", priority: 80)
ips << IPAddress.create!(ip_pool: pool3, ipv4: "192.168.3.30", hostname: "transact1.example.com", priority: 100)
ips << IPAddress.create!(ip_pool: pool3, ipv4: "192.168.3.31", hostname: "transact2.example.com", priority: 95)
puts "   ✓ Created #{ips.count} IP Addresses"

# Create IP Reputation Metrics
puts "\n3. Creating IP Reputation Metrics..."
metrics_count = 0
ips.each_with_index do |ip, idx|
  # Create metrics for the last 7 days only (for speed)
  7.downto(0) do |days_ago|
    date = days_ago.days.ago

    # Vary reputation scores based on IP
    base_score = case idx
                 when 0 then 95  # Excellent IP
                 when 1 then 85  # Good IP
                 when 2 then 70  # Fair IP (has some issues)
                 when 3 then 45  # Poor IP (blacklisted)
                 when 4 then 88  # Good IP
                 when 5 then 92  # Excellent IP
                 end

    # Add some variation over time
    score = base_score + rand(-5..5)
    score = score.clamp(0, 100)

    # Calculate realistic metrics
    total_sent = rand(100..1000)
    delivery_rate = (score * 0.9) + rand(0..10)
    bounce_rate = (100 - delivery_rate) * 0.7
    spam_rate = (100 - score) * 0.1

    total_delivered = (total_sent * delivery_rate / 100).to_i
    total_bounced = (total_sent * bounce_rate / 100).to_i
    total_spam = (total_sent * spam_rate / 100).to_i

    IPReputationMetric.create!(
      ip_address: ip,
      period_date: date.to_date,
      period: "daily",
      metric_type: "internal",
      reputation_score: score,
      delivery_rate: delivery_rate.round(2),
      bounce_rate: bounce_rate.round(2),
      spam_rate: spam_rate.round(2),
      sent_count: total_sent,
      delivered_count: total_delivered,
      bounced_count: total_bounced,
      spam_complaint_count: total_spam,
      soft_fail_count: (total_bounced * 0.6).to_i,
      hard_fail_count: (total_bounced * 0.4).to_i
    )
    metrics_count += 1
  end
end
puts "   ✓ Created #{metrics_count} reputation metrics"

# Create Blacklist Records
puts "\n4. Creating Blacklist Records..."
blacklists = []

# Active blacklistings on the poor IP
blacklists << IPBlacklistRecord.create!(
  ip_address: ips[3],
  blacklist_source: "Spamhaus ZEN",
  destination_domain: "gmail.com",
  detected_at: 3.days.ago,
  status: "active",
  detection_method: "dnsbl_check",
  last_checked_at: 1.hour.ago,
  check_count: 72
)

blacklists << IPBlacklistRecord.create!(
  ip_address: ips[3],
  blacklist_source: "Spamcop",
  destination_domain: nil,
  detected_at: 5.days.ago,
  status: "active",
  detection_method: "dnsbl_check",
  last_checked_at: 1.hour.ago,
  check_count: 120
)

# Resolved blacklisting on fair IP
blacklists << IPBlacklistRecord.create!(
  ip_address: ips[2],
  blacklist_source: "Barracuda",
  destination_domain: "outlook.com",
  detected_at: 10.days.ago,
  resolved_at: 3.days.ago,
  status: "resolved",
  detection_method: "smtp_analysis",
  smtp_response_code: "550",
  smtp_response_message: "IP blocked by Barracuda",
  last_checked_at: 2.days.ago,
  check_count: 168
)

# Old resolved blacklisting
blacklists << IPBlacklistRecord.create!(
  ip_address: ips[1],
  blacklist_source: "SORBS",
  destination_domain: nil,
  detected_at: 30.days.ago,
  resolved_at: 25.days.ago,
  status: "resolved",
  detection_method: "dnsbl_check",
  last_checked_at: 24.days.ago,
  check_count: 144
)

# Recent blacklisting that was ignored (false positive)
blacklists << IPBlacklistRecord.create!(
  ip_address: ips[4],
  blacklist_source: "UCEPROTECT",
  destination_domain: nil,
  detected_at: 7.days.ago,
  status: "ignored",
  detection_method: "dnsbl_check",
  details: { note: "False positive - entire /24 block listed" },
  last_checked_at: 1.day.ago,
  check_count: 168
)

puts "   ✓ Created #{blacklists.count} blacklist records"

# Create Domain Exclusions (warmup stages)
puts "\n5. Creating Domain Exclusions..."
exclusions = []

# IP warming up after blacklist resolution (stage 2)
exclusions << IPDomainExclusion.create!(
  ip_address: ips[2],
  destination_domain: "outlook.com",
  warmup_stage: 2,
  excluded_at: 7.days.ago,
  next_warmup_at: 2.days.from_now,
  reason: "Recovering from Barracuda blacklist",
  ip_blacklist_record: blacklists[2]
)

# IP paused (stage 0) due to active blacklisting
exclusions << IPDomainExclusion.create!(
  ip_address: ips[3],
  destination_domain: "gmail.com",
  warmup_stage: 0,
  excluded_at: 3.days.ago,
  reason: "Paused: Listed on Spamhaus ZEN",
  ip_blacklist_record: blacklists[0]
)

exclusions << IPDomainExclusion.create!(
  ip_address: ips[3],
  destination_domain: "yahoo.com",
  warmup_stage: 0,
  excluded_at: 5.days.ago,
  reason: "Paused: Listed on Spamcop",
  ip_blacklist_record: blacklists[1]
)

# IP in advanced warmup (stage 4)
exclusions << IPDomainExclusion.create!(
  ip_address: ips[1],
  destination_domain: "aol.com",
  warmup_stage: 4,
  excluded_at: 12.days.ago,
  next_warmup_at: 2.days.from_now,
  reason: "Warmup after SORBS delisting",
  ip_blacklist_record: blacklists[3]
)

puts "   ✓ Created #{exclusions.count} domain exclusions"

# Get admin user for health actions
admin_user = User.first

# Create Health Actions
puts "\n6. Creating Health Actions..."
actions = []

# Automatic pause due to blacklisting
actions << IPHealthAction.create!(
  ip_address: ips[3],
  action_type: "PAUSE",
  destination_domain: "gmail.com",
  reason: "Automatic pause: detected on Spamhaus ZEN",
  created_at: 3.days.ago,
  triggered_by_blacklist: blacklists[0]
)

actions << IPHealthAction.create!(
  ip_address: ips[3],
  action_type: "PAUSE",
  destination_domain: "yahoo.com",
  reason: "Automatic pause: detected on Spamcop",
  created_at: 5.days.ago,
  triggered_by_blacklist: blacklists[1]
)

# Manual resolution and warmup start
actions << IPHealthAction.create!(
  ip_address: ips[2],
  action_type: "UNPAUSE",
  destination_domain: "outlook.com",
  reason: "Manual unpause by admin: delisting confirmed",
  user: admin_user,
  created_at: 7.days.ago
)

# Warmup stage advancements
actions << IPHealthAction.create!(
  ip_address: ips[2],
  action_type: "WARMUP_STAGE_ADVANCE",
  destination_domain: "outlook.com",
  reason: "Automatic warmup advancement: stage 0 → 1",
  created_at: 5.days.ago
)

actions << IPHealthAction.create!(
  ip_address: ips[2],
  action_type: "WARMUP_STAGE_ADVANCE",
  destination_domain: "outlook.com",
  reason: "Automatic warmup advancement: stage 1 → 2",
  created_at: 1.day.ago
)

actions << IPHealthAction.create!(
  ip_address: ips[1],
  action_type: "WARMUP_STAGE_ADVANCE",
  destination_domain: "aol.com",
  reason: "Manual advancement by admin",
  user: admin_user,
  created_at: 2.days.ago
)

# Priority changes
actions << IPHealthAction.create!(
  ip_address: ips[1],
  action_type: "PRIORITY_CHANGE",
  destination_domain: nil,
  reason: "Priority adjusted: 100 → 90",
  user: admin_user,
  created_at: 15.days.ago
)

# Monitor actions
actions << IPHealthAction.create!(
  ip_address: ips[0],
  action_type: "MONITOR",
  destination_domain: nil,
  reason: "Routine health check: all systems normal",
  created_at: 1.hour.ago
)

puts "   ✓ Created #{actions.count} health actions"

puts "\n" + ("=" * 60)
puts "Sample data created successfully!"
puts "=" * 60
puts "\nSummary:"
puts "  • #{IPPool.count} IP Pools"
puts "  • #{IPAddress.count} IP Addresses"
puts "  • #{IPReputationMetric.count} Reputation Metrics"
puts "  • #{IPBlacklistRecord.count} Blacklist Records (#{IPBlacklistRecord.active.count} active)"
puts "  • #{IPDomainExclusion.count} Domain Exclusions"
puts "  • #{IPHealthAction.count} Health Actions"
puts "\nYou can now explore the IP Reputation dashboard with realistic data!"
puts "\nQuick links:"
puts "  • Dashboard: http://127.0.0.1:15000/ip_reputation/dashboard"
puts "  • IP Health: http://127.0.0.1:15000/ip_reputation/health"
puts "  • Trends: http://127.0.0.1:15000/ip_reputation/trends"
puts "=" * 60
