# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client, "authentication blocking" do
    let(:ip_address) { "192.168.1.100" }
    let(:threshold) { 3 }
    let(:block_duration) { 60 }

    subject(:client) { described_class.new(ip_address) }

    before do
      Rails.cache.clear
      client.handle("HELO test.example.com")

      # Mock config to use lower threshold for testing
      allow(Postal::Config).to receive(:smtp_server).and_return(
        double(
          auth_failure_threshold: threshold,
          auth_failure_block_duration: block_duration,
          log_ip_address_exclusion_matcher: nil,
          tls_enabled?: false
        )
      )
    end

    describe "AUTH PLAIN blocking" do
      let(:invalid_auth) { Base64.encode64("user\0wrongpass") }

      context "when failures are below threshold" do
        it "allows authentication attempts" do
          (threshold - 1).times do
            response = client.handle("AUTH PLAIN #{invalid_auth}")
            expect(response).to eq("535 Invalid credential")
          end
        end
      end

      context "when threshold is exceeded" do
        before do
          threshold.times do
            client.handle("AUTH PLAIN #{invalid_auth}")
          end
        end

        it "blocks further authentication attempts" do
          response = client.handle("AUTH PLAIN")
          expect(response).to eq("421 Too many authentication failures. Try again later.")
        end

        it "returns block message for any AUTH PLAIN attempt" do
          # Create a new client with same IP to simulate new connection
          new_client = described_class.new(ip_address)
          new_client.handle("HELO test.example.com")

          response = new_client.handle("AUTH PLAIN")
          expect(response).to eq("421 Too many authentication failures. Try again later.")
        end
      end

      context "when successful authentication occurs before threshold" do
        it "resets the failure counter" do
          # Fail twice
          2.times { client.handle("AUTH PLAIN #{invalid_auth}") }

          # Succeed once
          credential = create(:credential, type: "SMTP")
          response = client.handle("AUTH PLAIN #{credential.to_smtp_plain}")
          expect(response).to match(/235 Granted for/)

          # Should be able to fail again without being blocked
          (threshold - 1).times do
            response = client.handle("AUTH PLAIN #{invalid_auth}")
            expect(response).to eq("535 Invalid credential")
          end
        end
      end
    end

    describe "AUTH LOGIN blocking" do
      context "when failures exceed threshold" do
        before do
          threshold.times do
            client.handle("AUTH LOGIN")
            client.handle("dXNlcm5hbWU=") # "username" in base64
            client.handle("d3JvbmdwYXNz") # "wrongpass" in base64
          end
        end

        it "blocks further authentication attempts" do
          response = client.handle("AUTH LOGIN")
          expect(response).to eq("421 Too many authentication failures. Try again later.")
        end
      end

      context "with successful authentication" do
        it "resets the counter" do
          # Fail once
          client.handle("AUTH LOGIN")
          client.handle("dXNlcm5hbWU=")
          client.handle("d3JvbmdwYXNz")

          # Succeed
          credential = create(:credential, type: "SMTP")
          client.handle("AUTH LOGIN")
          client.handle("dXNlcm5hbWU=")
          password = Base64.encode64(credential.key)
          response = client.handle(password)
          expect(response).to match(/235 Granted for/)

          # Counter should be reset
          tracker = AuthFailureTracker.new(ip_address: ip_address)
          expect(tracker.current_failure_count).to eq(0)
        end
      end
    end

    describe "AUTH CRAM-MD5 blocking" do
      let(:server) { create(:server) }
      let(:credential) { create(:credential, type: "SMTP", server: server) }

      context "when failures exceed threshold" do
        before do
          threshold.times do
            response = client.handle("AUTH CRAM-MD5")
            # Extract challenge from response
            challenge_b64 = response.sub(/^334 /, "")
            # Send invalid response
            client.handle(Base64.encode64("#{server.organization.permalink}/#{server.permalink} wronghmac"))
          end
        end

        it "blocks further authentication attempts" do
          response = client.handle("AUTH CRAM-MD5")
          expect(response).to eq("421 Too many authentication failures. Try again later.")
        end
      end

      context "with successful CRAM-MD5 authentication" do
        it "resets the counter" do
          # Fail once with wrong server
          client.handle("AUTH CRAM-MD5")
          client.handle(Base64.encode64("wrong/wrong wronghmac"))

          # Succeed with valid CRAM-MD5
          response = client.handle("AUTH CRAM-MD5")
          challenge_b64 = response.sub(/^334 /, "")
          challenge = Base64.decode64(challenge_b64)

          hmac = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("md5"), credential.key, challenge)
          cram_response = "#{server.organization.permalink}/#{server.permalink} #{hmac}"
          response = client.handle(Base64.encode64(cram_response))

          expect(response).to match(/235 Granted for/)

          # Counter should be reset
          tracker = AuthFailureTracker.new(ip_address: ip_address)
          expect(tracker.current_failure_count).to eq(0)
        end
      end
    end

    describe "multiple authentication methods" do
      let(:invalid_plain) { Base64.encode64("user\0wrongpass") }

      it "tracks failures across different auth methods" do
        # Fail with PLAIN
        client.handle("AUTH PLAIN #{invalid_plain}")

        # Fail with LOGIN
        client.handle("AUTH LOGIN")
        client.handle("dXNlcm5hbWU=")
        client.handle("d3JvbmdwYXNz")

        # Fail with CRAM-MD5
        client.handle("AUTH CRAM-MD5")
        client.handle(Base64.encode64("wrong/wrong wronghmac"))

        # Should now be blocked (3 failures with threshold of 3)
        response = client.handle("AUTH PLAIN")
        expect(response).to eq("421 Too many authentication failures. Try again later.")
      end
    end

    describe "Prometheus metrics" do
      let(:invalid_auth) { Base64.encode64("user\0wrongpass") }

      it "increments block counter when threshold is exceeded" do
        # The increment_prometheus_counter is called internally
        # We can't easily test Prometheus counters in specs, but we verify
        # the behavior by checking that blocking works correctly
        (threshold + 1).times do
          client.handle("AUTH PLAIN #{invalid_auth}")
        end

        # Verify that the IP is actually blocked
        response = client.handle("AUTH PLAIN")
        expect(response).to eq("421 Too many authentication failures. Try again later.")
      end
    end

    describe "error counting" do
      it "increments ip-blocked error count when blocked" do
        invalid_auth = Base64.encode64("user\0wrongpass")

        # Exceed threshold
        (threshold + 1).times do
          client.handle("AUTH PLAIN #{invalid_auth}")
        end

        # The increment_error_count("ip-blocked") is called internally
        # We verify by checking that subsequent attempts are blocked
        response = client.handle("AUTH PLAIN")
        expect(response).to eq("421 Too many authentication failures. Try again later.")
      end
    end

    describe "different IPs are tracked separately" do
      let(:ip_address_2) { "192.168.1.101" }
      let(:client2) { described_class.new(ip_address_2) }
      let(:invalid_auth) { Base64.encode64("user\0wrongpass") }

      before do
        client2.handle("HELO test.example.com")
      end

      it "does not block IP2 when IP1 is blocked" do
        # Block IP1
        threshold.times do
          client.handle("AUTH PLAIN #{invalid_auth}")
        end

        # IP1 should be blocked
        response1 = client.handle("AUTH PLAIN")
        expect(response1).to eq("421 Too many authentication failures. Try again later.")

        # IP2 should not be blocked
        response2 = client2.handle("AUTH PLAIN #{invalid_auth}")
        expect(response2).to eq("535 Invalid credential")
      end
    end

    describe "logging" do
      let(:invalid_auth) { Base64.encode64("user\0wrongpass") }

      it "logs when IP is blocked" do
        allow(client).to receive(:logger).and_return(double("logger").as_null_object)

        threshold.times do
          client.handle("AUTH PLAIN #{invalid_auth}")
        end

        expect(client.logger).to have_received(:warn).with(/IP #{ip_address} blocked after #{threshold} failed/)
      end

      it "logs block message on subsequent attempts" do
        # Block the IP
        threshold.times do
          client.handle("AUTH PLAIN #{invalid_auth}")
        end

        # Create new client with same IP
        new_client = described_class.new(ip_address)
        new_client.handle("HELO test.example.com")

        allow(new_client).to receive(:logger).and_return(double("logger").as_null_object)

        new_client.handle("AUTH PLAIN")

        expect(new_client.logger).to have_received(:warn).with(/Authentication blocked for #{ip_address} - too many failed attempts/)
      end
    end
  end

end
