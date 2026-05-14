if System.get_env("TEST_TARGET", "local") == "local" do
  import Config

  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx",
    codex_path: "codex"
else
  import Config

  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx",
    codex_path: "/app/node_modules/.bin/codex"
end
