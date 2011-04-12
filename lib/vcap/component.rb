# Copyright (c) 2009-2011 VMware, Inc.
require "eventmachine"
require 'thin'
require "yajl"
require "nats/client"
require "base64"
require 'set'

module VCAP

  RACK_JSON_HDR = { 'Content-Type' => 'application/json' }
  RACK_TEXT_HDR = { 'Content-Type' => 'text/plaintext' }

  class Varz
    def call(env)
      varz = Yajl::Encoder.encode(Component.updated_varz, :pretty => true, :terminator => "\n")
      [200, { 'Content-Type' => 'application/json' }, varz]
    end
  end

  # Common component setup for discovery and monitoring
  class Component

    # We will suppress these from normal varz reporting by default.
    CONFIG_SUPPRESS = Set.new([:mbus, :keys])

    class << self

      attr_reader   :varz
      attr_accessor :healthz

      def updated_varz
        @last_varz_update ||= 0
        if Time.now.to_f - @last_varz_update >= 1
          # Snapshot uptime
          @varz[:uptime] = VCAP.uptime_string(Time.now - @varz[:start])

          # Grab current cpu and memory usage.
          rss, pcpu = `ps -o rss=,pcpu= -p #{Process.pid}`.split
          @varz[:mem] = rss.to_i
          @varz[:cpu] = pcpu.to_f

          @last_varz_update = Time.now.to_f
        end
        varz
      end

      def updated_healthz
        @last_healthz_update ||= 0
        if Time.now.to_f - @last_healthz_update >= 1
          # ...
          @last_healthz_update = Time.now.to_f
        end

        healthz
      end

      def start_http_server(host, port, auth)
        http_server = Thin::Server.new(host, port, :signals => false) do
          Thin::Logging.silent = true
          use Rack::Auth::Basic do |username, password|
            [username, password] == auth
          end
          map '/healthz' do
            run lambda { |env| [200, RACK_TEXT_HDR, Component.updated_healthz] }
          end
          map '/varz' do
            run Varz.new
          end
        end
        http_server.start!
      end

      def uuid
        @discover[:uuid]
      end

      def register(opts)
        uuid = VCAP.fast_uuid
        type = opts[:type]
        host = opts[:host] || VCAP.local_ip
        port = VCAP.grab_ephemeral_port
        nats = opts[:nats] || NATS
        auth = [VCAP.fast_uuid, VCAP.fast_uuid]

        # Discover message limited
        @discover = {
          :type => type,
          :uuid => uuid,
          :host => "#{host}:#{port}",
          :credentials => auth,
          :start => Time.now }

        # Varz is customizable
        @varz = @discover.dup
        @varz[:num_cores] = VCAP.num_cores
        @varz[:config] = sanitize_config(opts[:config]) if opts[:config]

        @healthz = "ok\n".freeze

        # Next steps require EM
        raise "EventMachine reactor needs to be running" if !EventMachine.reactor_running?

        # Startup the http endpoint for /varz and /healthz
        start_http_server(host, port, auth)

        # Listen for discovery requests
        nats.subscribe('vcap.component.discover') do |msg, reply|
          update_discover_uptime
          nats.publish(reply, @discover.to_json)
        end

        # Also announce ourselves on startup..
        nats.publish('vcap.component.announce', @discover.to_json)
      end

      def update_discover_uptime
        @discover[:uptime] = VCAP.uptime_string(Time.now - @discover[:start])
      end

      def sanitize_config(config)
        config = config.dup
        config.each { |k, v| config.delete(k) if CONFIG_SUPPRESS.include?(k.to_sym) }
        config
      end
    end
  end
end
