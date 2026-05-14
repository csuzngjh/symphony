import Config

if System.get_env("TEST_TARGET", "local") == "local" do
  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx",
    codex_path: "codex"
else
  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx",
    codex_path: "/app/node_modules/.bin/codex"
end
