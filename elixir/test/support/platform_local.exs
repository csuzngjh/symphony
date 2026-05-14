import Config

if System.get_env("TEST_TARGET", "local") == "local" do
  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx",
else
  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx",
end
