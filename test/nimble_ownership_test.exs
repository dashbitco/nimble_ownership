defmodule NimbleOwnershipTest do
  use ExUnit.Case
  doctest NimbleOwnership

  test "allowances are transitive" do
    server = start_supervised!(NimbleOwnership)
    parent_pid = self()

    {:ok, child_pid} =
      start_link_no_callers(fn ->
        receive do
          :call_mock ->
            owner = NimbleOwnership.get_owner(server, callers(), :some_key)
            send(parent_pid, {:owner, owner})
        end
      end)

    transitive_pid =
      spawn_link(fn ->
        receive do
          :allow_child ->
            NimbleOwnership.allow(server, self(), child_pid, :some_key, %{counter: 2})
            send(child_pid, :call_mock)
        end
      end)

    NimbleOwnership.allow(server, self(), transitive_pid, :some_key, %{counter: 1})
    send(transitive_pid, :allow_child)

    assert_receive {:owner, owner}
    assert owner == %{metadata: %{counter: 1}, owner_pid: parent_pid}
  end

  test "allowances support lazy calls for processes registered through a Registry" do
    start_supervised!({NimbleOwnership, name: LazyServerTest})

    defmodule LazyServer do
      use GenServer

      def start_link(name), do: GenServer.start_link(__MODULE__, [], name: name)

      def init(args), do: {:ok, args}

      def handle_call(:get_owner, _from, state) do
        {:reply, NimbleOwnership.get_owner(LazyServerTest, [self()], :some_key), state}
      end
    end

    start_supervised!({Registry, keys: :unique, name: Registry.Test})
    name = {:via, Registry, {Registry.Test, :test_process_lazy}}

    NimbleOwnership.allow(
      LazyServerTest,
      self(),
      fn -> GenServer.whereis(name) end,
      :some_key,
      :meta
    )

    start_supervised!({LazyServer, name})

    assert GenServer.call(name, :get_owner) == %{metadata: :meta, owner_pid: self()}
  end

  defp callers do
    [self()] ++ Process.get(:"$callers", [])
  end

  defp start_link_no_callers(fun) do
    Task.start_link(fn ->
      Process.delete(:"$callers")
      fun.()
    end)
  end
end
