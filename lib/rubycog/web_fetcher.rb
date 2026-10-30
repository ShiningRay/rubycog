# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'zlib'

module Rubycog
  # Minimal HTTP fetcher for learning from external sources. Stdlib only —
  # no Nokogiri, no HTTParty. Follows redirects up to a small limit, times out
  # aggressively, strips scripts/styles from HTML, and caps response size so
  # a single URL cannot blow up the context window.
  class WebFetcher
    MAX_REDIRECTS = 3
    MAX_BYTES = 200 * 1024
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    USER_AGENT = 'RubyCog/0.1 (+https://github.com/ShiningRay/rubycog)'.freeze
    ALLOWED_SCHEMES = %w[http https].freeze

    Result = Data.define(:url, :status, :content_type, :body, :error) do
      def ok? = error.nil? && status.to_i.between?(200, 299)
    end

    def self.fetch(url)
      new.fetch(url)
    end

    def fetch(url, redirects_left: MAX_REDIRECTS)
      uri = parse_uri(url)
      return failure(url, "invalid URL or unsupported scheme: #{url}") unless uri

      response = perform_request(uri)
      case response
      when Net::HTTPRedirection
        return failure(url, 'too many redirects') if redirects_left.zero?

        location = response['location']
        return failure(url, 'redirect missing Location header') if location.to_s.empty?

        fetch(URI.join(uri, location).to_s, redirects_left: redirects_left - 1)
      else
        body = extract_body(response)
        Result.new(url: url, status: response.code.to_i,
                   content_type: response['content-type'].to_s,
                   body: body, error: nil)
      end
    rescue StandardError => e
      failure(url, "#{e.class}: #{e.message}")
    end

    private

    def parse_uri(url)
      uri = URI.parse(url.to_s.strip)
      return nil unless ALLOWED_SCHEMES.include?(uri.scheme)
      return nil if uri.host.to_s.empty?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def perform_request(uri)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https',
                      open_timeout: OPEN_TIMEOUT,
                      read_timeout: READ_TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = USER_AGENT
        request['Accept'] = 'text/html,text/plain,application/xhtml+xml,*/*;q=0.8'
        http.request(request)
      end
    end

    def extract_body(response)
      raw = response.body.to_s
      raw = raw.byteslice(0, MAX_BYTES) if raw.bytesize > MAX_BYTES
      content_type = response['content-type'].to_s.downcase

      if content_type.include?('html')
        html_to_text(raw)
      else
        raw
      end
    end

    # Crude HTML to text. Strips script/style, drops tags, collapses whitespace.
    # We are not aiming for readability here — the consumer is an LLM that
    # tolerates noise better than it tolerates truncation.
    def html_to_text(html)
      text = html.dup
      text.gsub!(%r{<script\b[^>]*>.*?</script>}mi, ' ')
      text.gsub!(%r{<style\b[^>]*>.*?</style>}mi, ' ')
      text.gsub!(/<!--.*?-->/m, ' ')
      text.gsub!(%r{</(p|div|li|tr|h[1-6]|section|article|header|footer)>}i, "\n")
      text.gsub!(/<br\s*\/?>/i, "\n")
      text.gsub!(/<[^>]+>/, ' ')
      text.gsub!(/&nbsp;/i, ' ')
      text.gsub!(/&amp;/i, '&')
      text.gsub!(/&lt;/i, '<')
      text.gsub!(/&gt;/i, '>')
      text.gsub!(/&quot;/i, '"')
      text.gsub!(/&#39;|&apos;/i, "'")
      text.gsub!(/[ \t]+/, ' ')
      text.gsub!(/\n\s*\n+/, "\n\n")
      text.strip
    end

    def failure(url, message)
      Result.new(url: url, status: 0, content_type: '', body: '', error: message)
    end
  end
end
