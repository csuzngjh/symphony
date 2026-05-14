target = System.get_env("TEST_TARGET", "local")

if target == "local" do
  Application.put_env(:symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "acpx",
    codex_path: "codex"
  )
else
  Application.put_env(:symphony_elixir, SymphonyElixir.AgentRunner,
    acpx_path: "/app/node_modules/.bin/acpx",
    codex_path: "/app/node_modules/.bin/codex"
  )
end

ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
