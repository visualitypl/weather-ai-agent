#!/usr/bin/env ruby
require "net/http"
require "json"
require "uri"
require "dotenv/load"

DEBUG = ENV["DEBUG"] != "0"

def debug(label, data = nil)
  return unless DEBUG
  line = "[debug] #{label}"
  line += " #{data.is_a?(String) ? data : JSON.dump(data)}" unless data.nil?
  warn line
end

module Http
  module_function

  def get_json(url, **params)
    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    JSON.parse(Net::HTTP.get(uri))
  end

  def post_json(url, headers:, body:)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri, headers.merge("Content-Type" => "application/json"))
    req.body = JSON.dump(body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    res = http.request(req)
    raise "HTTP #{res.code}: #{res.body}" unless res.code.to_i == 200
    JSON.parse(res.body)
  end
end

module Weather
  GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
  FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
  CURRENT_FIELDS = "temperature_2m,wind_speed_10m,relative_humidity_2m,weather_code"

  SCHEMA = {
    type: "function",
    function: {
      name: "weather",
      description: "Get the current weather for a place by name (city, landmark, etc.).",
      parameters: {
        type: "object",
        properties: {
          location: {
            type: "string",
            description: "Name of the place, e.g. 'Paris' or 'Paris, France'."
          }
        },
        required: ["location"]
      }
    }
  }

  module_function

  def call(location:)
    place = geocode(location)
    return { error: "no location found for #{location.inspect}" } unless place
    format_current(place, fetch_current(place))
  rescue => error
    { error: error.message }
  end

  def geocode(name)
    Http.get_json(GEOCODE_URL, name: name, count: 1, language: "en", format: "json")
        .dig("results", 0)
  end

  def fetch_current(place)
    Http.get_json(FORECAST_URL,
                  latitude: place["latitude"],
                  longitude: place["longitude"],
                  current: CURRENT_FIELDS).fetch("current")
  end

  def format_current(place, current)
    {
      location: [place["name"], place["admin1"], place["country"]].compact.join(", "),
      temperature_c: current["temperature_2m"],
      humidity_pct: current["relative_humidity_2m"],
      wind_kmh: current["wind_speed_10m"],
      weather_code: current["weather_code"],
      observed_at: current["time"]
    }
  end
end

module Tools
  REGISTRY = { "weather" => Weather }
  SCHEMAS = REGISTRY.values.map { |t| t::SCHEMA }

  module_function

  def run(tool_call)
    name = tool_call.dig("function", "name")
    raw = tool_call.dig("function", "arguments")
    args = (raw.nil? || raw.empty?) ? {} : JSON.parse(raw)
    debug "  tool call: #{name}(#{args.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')})"

    tool = REGISTRY[name]
    return { error: "unknown tool #{name}" } unless tool

    result = tool.call(**args.transform_keys(&:to_sym))
    debug "  tool result:", result
    result
  end
end

module LLM
  API_URL = "https://openrouter.ai/api/v1/chat/completions"

  module_function

  def chat(messages)
    debug "→ POST openrouter.ai (#{messages.size} msgs, last=#{messages.last['role']})"

    body = Http.post_json(
      API_URL,
      headers: { "Authorization" => "Bearer #{ENV.fetch('OPENROUTER_API_KEY')}" },
      body: { model: ENV.fetch("LLM_DEFAULT_MODEL"),
              messages: messages,
              tools: Tools::SCHEMAS }
    )

    msg = body.dig("choices", 0, "message")
    log_reply(msg)
    msg
  end

  def log_reply(msg)
    if msg["tool_calls"]&.any?
      names = msg["tool_calls"].map { |tc| tc.dig("function", "name") }
      debug "← assistant wants tools: #{names.join(', ')}"
    else
      content = msg["content"].to_s
      preview = content.gsub(/\s+/, " ")[0, 120]
      debug "← assistant content (#{content.length} chars): #{preview}"
    end
  end
end

SYSTEM_PROMPT = <<~PROMPT
  You are a terminal assistant. Use the weather tool whenever the user asks
  about current weather, temperature, wind, or humidity for a place.
PROMPT

def ask(messages, user_input)
  messages << { "role" => "user", "content" => user_input }

  loop do
    msg = LLM.chat(messages)
    messages << msg

    tool_calls = msg["tool_calls"]
    return msg["content"] if tool_calls.nil? || tool_calls.empty?

    tool_calls.each do |tc|
      messages << {
        "role" => "tool",
        "tool_call_id" => tc["id"],
        "content" => JSON.dump(Tools.run(tc))
      }
    end
  end
end

def run_repl
  puts "ruby AI agent — type 'exit' or Ctrl-D to quit"
  messages = [{ "role" => "system", "content" => SYSTEM_PROMPT }]

  loop do
    print "\n> "
    input = $stdin.gets
    break if input.nil?
    msg = input.strip
    next if msg.empty?
    break if %w[exit quit].include?(msg)

    begin
      puts ask(messages, msg)
    rescue Interrupt
      puts "\n[interrupted]"
    rescue => error
      warn "\n[error] #{error.class}: #{error.message}"
    end
  end
end

run_repl
