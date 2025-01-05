ExUnit.start()

# Ensure clean shutdown between tests
Application.ensure_all_started(:elixir_raft)
