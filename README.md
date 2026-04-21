# ruby weather AI agent

A minimal terminal AI agent in Ruby — a single file, no agent framework. It talks directly to the OpenRouter chat-completions API and implements tool use by hand.

## What it does

- Reads prompts from stdin in a REPL.
- Sends each turn to the LLM along with a list of available tool schemas.
- When the LLM asks for a tool, runs the Ruby code locally, sends the result back, and loops until the LLM produces a final answer.
- Ships with one example tool, `weather`, backed by the free [Open-Meteo](https://open-meteo.com) API.

## Run

```sh
bundle install
cp .env.example .env    # add OPENROUTER_API_KEY and LLM_DEFAULT_MODEL
ruby agent.rb
```

Example session:

```
> what's the weather in Paris?
Paris is currently 17.3°C with 55% humidity and winds around 12 km/h.
```

Set `DEBUG=0` to silence the `[debug]` lines on stderr.
