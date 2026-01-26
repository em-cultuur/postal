# frozen_string_literal: true

# Rack::Attack middleware for rate limiting API endpoints
class Rack::Attack

  # Throttle MX rate limits API endpoints to 60 requests per minute per IP
  throttle("mx_rate_limits_api/ip", limit: 60, period: 60.seconds) do |req|
    # Only apply rate limiting to MX rate limits API endpoints
    if req.path.match?(/\/org\/[^\/]+\/servers\/[^\/]+\/mx_rate_limits/)
      req.ip
    end
  end

  # Throttle stats endpoint to 120 requests per minute per IP (higher limit for data queries)
  throttle("mx_rate_limits_stats/ip", limit: 120, period: 60.seconds) do |req|
    if req.path.match?(/\/org\/[^\/]+\/servers\/[^\/]+\/mx_rate_limits\/[^\/]+\/stats/)
      req.ip
    end
  end

end

# Customize responses for throttled requests
Rack::Attack.throttled_response = lambda { |env|
  now = Time.current

  match_data = env["rack.attack.match_data"]
  period = match_data[:period]
  limit = match_data[:limit]
  retry_after = period - (now.to_i % period)

  [
    429,
    {
      "Content-Type" => "application/json",
      "Retry-After" => retry_after.to_s
    },
    [
      {
        error: "Rate limit exceeded. Maximum #{limit} requests per #{period} seconds allowed.",
        retry_after: retry_after
      }.to_json,
    ],
  ]
}
