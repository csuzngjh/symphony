if System.get_env("TEST_TARGET", "local") == "local" do
  import Config

  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx",
else
  import Config

  config :symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx",
end
