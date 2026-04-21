#!/usr/bin/env ruby
require "net/http"
require "json"
require "uri"
require "dotenv/load"

API_URL = URI("https://openrouter.ai/api/v1/chat/completions")

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
    get_json(GEOCODE_URL, name: name, count: 1, language: "en", format: "json")
      .dig("results", 0)
  end

  def fetch_current(place)
    get_json(FORECAST_URL,
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

  def get_json(base, **params)
    uri = URI(base)
    uri.query = URI.encode_www_form(params)
    JSON.parse(Net::HTTP.get(uri))
  end
end

TOOLS = { "weather" => Weather }
TOOL_SCHEMAS = TOOLS.values.map { |t| t::SCHEMA }

SYSTEM_PROMPT = <<~PROMPT
  You are a terminal assistant. Use the weather tool whenever the user asks
  about current weather, temperature, wind, or humidity for a place. Keep
  answers concise.
PROMPT

def call_llm(messages)
  req = Net::HTTP::Post.new(API_URL, {
    "Authorization" => "Bearer #{ENV.fetch('OPENROUTER_API_KEY')}",
    "Content-Type" => "application/json"
  })
  req.body = JSON.dump(
    model: ENV.fetch("LLM_DEFAULT_MODEL"),
    messages: messages,
    tools: TOOL_SCHEMAS
  )

  http = Net::HTTP.new(API_URL.host, API_URL.port)
  http.use_ssl = true
  res = http.request(req)
  raise "LLM error #{res.code}: #{res.body}" unless res.code.to_i == 200

  JSON.parse(res.body).dig("choices", 0, "message")
end

def run_tool(call)
  name = call.dig("function", "name")
  raw = call.dig("function", "arguments")
  args = (raw.nil? || raw.empty?) ? {} : JSON.parse(raw)
  tool = TOOLS[name]
  return { error: "unknown tool #{name}" } unless tool
  tool.call(**args.transform_keys(&:to_sym))
end

def ask(messages, user_input)
  messages << { role: "user", content: user_input }

  loop do
    msg = call_llm(messages)
    messages << msg

    tool_calls = msg["tool_calls"]
    return msg["content"] if tool_calls.nil? || tool_calls.empty?

    tool_calls.each do |tc|
      result = run_tool(tc)
      messages << {
        role: "tool",
        tool_call_id: tc["id"],
        content: JSON.dump(result)
      }
    end
  end
end

def run_repl
  puts "ruby AI agent — type 'exit' or Ctrl-D to quit"
  messages = [{ role: "system", content: SYSTEM_PROMPT }]

  loop do
    print "\n> "
    input = $stdin.gets
    break if input.nil?
    msg = input.strip
    next if msg.empty?
    break if %w[exit quit].include?(msg)

    begin
      reply = ask(messages, msg)
      puts reply
    rescue Interrupt
      puts "\n[interrupted]"
    rescue => error
      warn "\n[error] #{error.class}: #{error.message}"
    end
  end
end

run_repl
