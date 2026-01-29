# frozen_string_literal: true

# Quick seed script for IP Reputation Management - Sample Data
# Run with: bundle exec rails runner db/seeds/ip_reputation_quick_seed.rb

puts "Creating sample data for IP Reputation Management..."

# Create IP Pools
puts "\n1. Creating IP Pools..."
pool1 = IPPool.find_or_create_by!(name: "Primary Pool")
pool2 = IPPool.find_or_create_by!(name: "Marketing Pool")
pool3 = IPPool.find_or_create_by!(name: "Transactional Pool")
puts "   ✓ Created 3 IP Pools"

# Create IP Addresses
puts "\n2. Creating IP Addresses..."
ips = []
ips << IPAddress.find_or_create_by!(ipv4: "192.168.1.10") do |ip|
  ip.ip_pool = pool1
  ip.hostname = "mail1.example.com"
  ip.priority = 100
end

ips << IPAddress.find_or_create_by!(ipv4: "192.168.1.11") do |ip|
  ip.ip_pool = pool1
  ip.hostname = "mail2.example.com"
  ip.priority = 90
end

ips << IPAddress.find_or_create_by!(ipv4: "192.168.2.20") do |ip|
  ip.ip_pool = pool2
  ip.hostname = "marketing1.example.com"
  ip.priority = 100
end

ips << IPAddress.find_or_create_by!(ipv4: "192.168.2.21") do |ip|
  ip.ip_pool = pool2
  ip.hostname = "marketing2.example.com"
  ip.priority = 80
end

ips << IPAddress.find_or_create_by!(ipv4: "192.168.3.30") do |ip|
  ip.ip_pool = pool3
  ip.hostname = "transact1.example.com"
  ip.priority = 100
end

ips << IPAddress.find_or_create_by!(ipv4: "192.168.3.31") do |ip|
  ip.ip_pool = pool3
  ip.hostname = "transact2.example.com"
  ip.priority = 95
end

puts "   ✓ Created #{ips.count} IP Addresses"

# Create sample reputation metrics for each IP (last 3 days only)
puts "\n3. Creating IP Reputation Metrics (last 3 days)..."
reputation_scores = [95, 85, 70, 45, 88, 92] # Different scores for each IP

ips.each_with_index do |ip, idx|
  3.downto(0).each do |days_ago|
    date = days_ago.days.ago.to_date

    next if IPReputationMetric.exists?(ip_address: ip, period_date: date)

    score = reputation_scores[idx] + rand(-3..3)
    score = score.clamp(0, 100)

    IPReputationMetric.create!(
      ip_address: ip,
      period_date: date,
      period: "daily",
      metric_type: "internal",
      reputation_score: score,
      delivery_rate: ((score * 0.9) + rand(0..5)).round(2),
      bounce_rate: ((100 - score) * 0.5).round(2),
      spam_rate: ((100 - score) * 0.1).round(2),
      sent_count: rand(100..500),
      delivered_count: rand(80..450),
      bounced_count: rand(5..50),
      spam_complaint_count: rand(0..5),
      soft_fail_count: rand(3..30),
      hard_fail_count: rand(2..20)
    )
  end
end

metrics_count = IPReputationMetric.count
puts "   ✓ Created reputation metrics (total: #{metrics_count})"

# Create Blacklist Records
puts "\n4. Creating Blacklist Records..."

# Active blacklist on IP 4 (poor reputation)
bl1 = IPBlacklistRecord.find_or_create_by!(
  ip_address: ips[3],
  blacklist_source: "Spamhaus ZEN",
  destination_domain: "gmail.com"
) do |bl|
  bl.detected_at = 3.days.ago
  bl.status = "active"
  bl.detection_method = "dnsbl_check"
  bl.last_checked_at = 1.hour.ago
  bl.check_count = 72
end

bl2 = IPBlacklistRecord.find_or_create_by!(
  ip_address: ips[3],
  blacklist_source: "Spamcop",
  destination_domain: nil
) do |bl|
  bl.detected_at = 5.days.ago
  bl.status = "active"
  bl.detection_method = "dnsbl_check"
  bl.last_checked_at = 1.hour.ago
  bl.check_count = 120
end

# Resolved blacklist on IP 3
bl3 = IPBlacklistRecord.find_or_create_by!(
  ip_address: ips[2],
  blacklist_source: "Barracuda",
  destination_domain: "outlook.com"
) do |bl|
  bl.detected_at = 10.days.ago
  bl.resolved_at = 3.days.ago
  bl.status = "resolved"
  bl.detection_method = "smtp_analysis"
  bl.smtp_response_code = "550"
  bl.last_checked_at = 2.days.ago
  bl.check_count = 168
end

puts "   ✓ Created #{IPBlacklistRecord.count} blacklist records"

# Create Domain Exclusions
puts "\n5. Creating Domain Exclusions..."

ex1 = IPDomainExclusion.find_or_create_by!(
  ip_address: ips[2],
  destination_domain: "outlook.com"
) do |ex|
  ex.warmup_stage = 2
  ex.excluded_at = 7.days.ago
  ex.next_warmup_at = 2.days.from_now
  ex.reason = "Recovering from Barracuda blacklist"
  ex.ip_blacklist_record = bl3
end

ex2 = IPDomainExclusion.find_or_create_by!(
  ip_address: ips[3],
  destination_domain: "gmail.com"
) do |ex|
  ex.warmup_stage = 0
  ex.excluded_at = 3.days.ago
  ex.reason = "Paused: Listed on Spamhaus ZEN"
  ex.ip_blacklist_record = bl1
end

ex3 = IPDomainExclusion.find_or_create_by!(
  ip_address: ips[3],
  destination_domain: "yahoo.com"
) do |ex|
  ex.warmup_stage = 0
  ex.excluded_at = 5.days.ago
  ex.reason = "Paused: Listed on Spamcop"
  ex.ip_blacklist_record = bl2
end

puts "   ✓ Created #{IPDomainExclusion.count} domain exclusions"

# Get admin user
admin_user = User.first

# Create Health Actions
puts "\n6. Creating Health Actions..."

IPHealthAction.find_or_create_by!(
  ip_address: ips[3],
  action_type: "PAUSE",
  destination_domain: "gmail.com",
  created_at: 3.days.ago
) do |action|
  action.reason = "Automatic pause: detected on Spamhaus ZEN"
  action.triggered_by_blacklist_id = bl1.id
end

IPHealthAction.find_or_create_by!(
  ip_address: ips[3],
  action_type: "PAUSE",
  destination_domain: "yahoo.com",
  created_at: 5.days.ago
) do |action|
  action.reason = "Automatic pause: detected on Spamcop"
  action.triggered_by_blacklist_id = bl2.id
end

IPHealthAction.find_or_create_by!(
  ip_address: ips[2],
  action_type: "UNPAUSE",
  destination_domain: "outlook.com",
  created_at: 7.days.ago
) do |action|
  action.reason = "Manual unpause by admin: delisting confirmed"
  action.user = admin_user
end

IPHealthAction.find_or_create_by!(
  ip_address: ips[2],
  action_type: "WARMUP_STAGE_ADVANCE",
  destination_domain: "outlook.com",
  created_at: 1.day.ago
) do |action|
  action.reason = "Automatic warmup advancement: stage 1 → 2"
end

puts "   ✓ Created #{IPHealthAction.count} health actions"

puts "\n" + ("=" * 60)
puts "Sample data created successfully!"
puts "=" * 60
puts "\nSummary:"
puts "  • #{IPPool.count} IP Pools"
puts "  • #{IPAddress.count} IP Addresses"
puts "  • #{IPReputationMetric.count} Reputation Metrics"
puts "  • #{IPBlacklistRecord.count} Blacklist Records"
puts "  • #{IPDomainExclusion.count} Domain Exclusions"
puts "  • #{IPHealthAction.count} Health Actions"
puts "\nQuick links:"
puts "  • Dashboard: http://127.0.0.1:15000/ip_reputation/dashboard"
puts "  • IP Health: http://127.0.0.1:15000/ip_reputation/health"
puts "=" * 60
