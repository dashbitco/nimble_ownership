defmodule NimbleOwnershipTest do
  use ExUnit.Case, async: true

  alias NimbleOwnership.Error

  doctest NimbleOwnership

  @server __MODULE__

  setup context do
    start_supervised!({NimbleOwnership, name: @server})
    %{key: context.test}
  end

  describe "start_link/1" do
    test "raises on invalid options" do
      assert_raise ArgumentError, "unknown options: [:invalid]", fn ->
        NimbleOwnership.start_link(invalid: :option)
      end
    end
  end

  describe "get_and_update/4" do
    test "inserts a new owner when there is no owner for the given key", %{key: key} do
      assert :ok =
               NimbleOwnership.get_and_update(@server, self(), key, fn arg ->
                 assert arg == nil
                 {:ok, %{counter: 1}}
               end)

      assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
      assert owner_pid == self()
    end

    test "updates the metadata with the returned value from the function", %{key: key} do
      test_pid = self()
      init_key(test_pid, key, %{counter: 1})

      assert :ok =
               NimbleOwnership.get_and_update(@server, test_pid, key, fn info ->
                 assert info == %{counter: 1}
                 {:ok, %{counter: 2}}
               end)

      assert {:ok, ^test_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
      assert get_meta(test_pid, key) == %{counter: 2}
    end

    defp get_meta(owner, key) do
      NimbleOwnership.get_and_update(@server, owner, key, fn meta ->
        assert meta != nil
        {meta, meta}
      end)
    end

    test "raises an error if the callback function returns an invalid value", %{key: key} do
      assert_raise ArgumentError, ~r"invalid return value from callback function", fn ->
        NimbleOwnership.get_and_update(@server, self(), key, fn nil -> :invalid_return end)
      end
    end
  end

  describe "allow/4" do
    test "returns an error if the PID that is supposed to have access doesn't have access",
         %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)
      random_pid_which_doesnt_have_access = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{})

      assert {:error, error} =
               NimbleOwnership.allow(@server, random_pid_which_doesnt_have_access, self(), key)

      assert error == %Error{key: key, reason: :not_allowed}
      assert Exception.message(error) =~ "this PID is not allowed to access key"
    end

    test "returns an error if the PID to allow is already allowed via another PID", %{key: key} do
      owner_pid1 = spawn(fn -> Process.sleep(:infinity) end)
      owner_pid2 = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid1, key, %{})
      init_key(owner_pid2, key, %{})

      assert :ok = NimbleOwnership.allow(@server, owner_pid1, self(), key)

      assert {:error, error} = NimbleOwnership.allow(@server, owner_pid2, self(), key)
      assert error == %Error{reason: {:already_allowed, owner_pid1}, key: key}
      assert Exception.message(error) =~ "this PID is already allowed to access key"
      assert Exception.message(error) =~ "via other owner"
    end

    test "supports transitive allowances", %{key: key} do
      parent_pid = self()

      {:ok, child1_pid} =
        Task.start_link(fn ->
          {:ok, child2_pid} =
            Task.start_link(fn ->
              receive do
                :go ->
                  assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, callers(), key)
                  assert owner_pid == parent_pid

                  NimbleOwnership.get_and_update(@server, owner_pid, key, fn info ->
                    assert info == %{counter: 1}
                    {:ok, %{counter: 2}}
                  end)

                  send(parent_pid, :done)
              end
            end)

          send(parent_pid, {:child2_pid, child2_pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:child2_pid, child2_pid}

      # Let's start with self() owning "key".
      init_key(parent_pid, key, %{counter: 1})

      # Now, we allow child_pid1 to access "key" through self(), and then we allow
      # child_pid2 to access "key" through child_pid1.
      assert :ok = NimbleOwnership.allow(@server, self(), child1_pid, key)
      assert :ok = NimbleOwnership.allow(@server, child1_pid, child2_pid, key)

      send(child2_pid, :go)
      assert_receive :done

      assert NimbleOwnership.fetch_owner(@server, [self()], key) == {:ok, self()}
      assert get_meta(self(), key) == %{counter: 2}
    end

    test "supports lazy allowed PIDs that resolve on the next upsert", %{key: key} do
      parent_pid = self()

      # Init the key.
      init_key(parent_pid, key, %{counter: 1})

      # Allow a lazy PID that will resolve later.
      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 self(),
                 fn -> Process.whereis(:lazy_pid) end,
                 key
               )

      {:ok, lazy_pid} =
        Task.start_link(fn ->
          receive do
            :go ->
              assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, callers(), key)
              assert owner_pid == parent_pid

              NimbleOwnership.get_and_update(@server, owner_pid, key, fn info ->
                assert info == %{counter: 1}
                {:ok, %{counter: 2}}
              end)

              send(parent_pid, :done)
          end
        end)

      Process.register(lazy_pid, :lazy_pid)

      send(lazy_pid, :go)
      assert_receive :done

      assert NimbleOwnership.fetch_owner(@server, [self()], key) == {:ok, self()}
      assert get_meta(self(), key) == %{counter: 2}
    end

    test "is idempotent", %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
    end
  end

  describe "get_owned/3" do
    test "returns all the owned keys + metadata for the given PID", %{key: key} do
      init_key(self(), :"#{key}_1", 1)
      init_key(self(), :"#{key}_2", 2)

      assert NimbleOwnership.get_owned(@server, self()) == %{
               :"#{key}_1" => 1,
               :"#{key}_2" => 2
             }
    end

    test "returns the default value if the PID doesn't own any keys" do
      ref = make_ref()
      assert NimbleOwnership.get_owned(@server, self(), ref) == ref
    end
  end

  describe "monitoring" do
    test "if a PID that owns a key shuts down, it's removed and all the allowances with it",
         %{key: key} do
      {owner_pid, monitor_ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      child_pid = spawn_link(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{counter: 1})

      # We init another key to show that monitoring the same owner even on multiple keys works.
      init_key(owner_pid, :"#{key}_2", %{counter: 1})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, child_pid, key)

      Process.exit(owner_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, _, _, _}

      assert :error = NimbleOwnership.fetch_owner(@server, [child_pid, owner_pid], key)
    end
  end

  defp callers do
    [self()] ++ Process.get(:"$callers", [])
  end

  defp init_key(owner, key, meta) do
    assert :ok = NimbleOwnership.get_and_update(@server, owner, key, fn nil -> {:ok, meta} end)
  end
end
