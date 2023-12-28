defmodule NimbleOwnershipTest do
  use ExUnit.Case, async: true

  alias NimbleOwnership.Error

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
      test_pid = self()

      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [], key, fn arg ->
                 assert arg == nil
                 {:set_owner, test_pid, :ok, %{counter: 1}}
               end)

      assert {:ok, %{owner_pid: ^test_pid}} = NimbleOwnership.get_owner(@server, [self()], key)
    end

    test "doesn't change the state if the function returns {:noop, _} and there is no owner",
         %{key: key} do
      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [], key, fn nil -> {:noop, :ok} end)

      assert :error = NimbleOwnership.get_owner(@server, [self()], key)
    end

    test "returns an error if the function returns :update_metadata, but there is no owner",
         %{key: key} do
      assert {:error, error} =
               NimbleOwnership.get_and_update(@server, [], key, fn nil ->
                 {:update_metadata, :ok, %{counter: 1}}
               end)

      assert error == %Error{key: key, reason: :cannot_update_metadata_on_non_existing}
      assert Exception.message(error) =~ "cannot return a :update_metadata tuple"

      assert :error = NimbleOwnership.get_owner(@server, [self()], key)
    end

    test "updates the meta when there is already an allowed PID in the callers and the function returns :update_metadata",
         %{key: key} do
      test_pid = self()
      init_key(test_pid, key, %{counter: 1})

      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [test_pid], key, fn info ->
                 assert info == %{owner_pid: test_pid, metadata: %{counter: 1}}
                 {:update_metadata, :ok, %{counter: 2}}
               end)

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: test_pid, metadata: %{counter: 2}}}
    end

    test "doesn't update the meta when there is already an allowed PID in the callers and the function returns :error",
         %{key: key} do
      init_key(self(), key, %{counter: 1})

      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [self()], key, fn _info -> {:noop, :ok} end)

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: self(), metadata: %{counter: 1}}}
    end

    test "returns an error when there is already an allowed PID in the callers and the function returns :set_owner",
         %{key: key} do
      init_key(self(), key, %{counter: 1})

      assert {:error, error} =
               NimbleOwnership.get_and_update(@server, [self()], key, fn _info ->
                 {:set_owner, self(), :ok, %{counter: 2}}
               end)

      assert error == %NimbleOwnership.Error{reason: {:cannot_reset_owner, self()}, key: key}
      assert Exception.message(error) =~ "cannot return a :set_owner tuple"

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: self(), metadata: %{counter: 1}}}
    end

    test "can update metadata even though the caller is not the owner of the key, as long as the caller is allowed",
         %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Insert with another PID as the owner.
      init_key(owner_pid, key, %{counter: 1})

      # Allow the current process to update the key (through "owner_pid").
      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)

      # Now, update the key even though the current process is not the owner.
      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [self()], key, fn info ->
                 assert info == %{owner_pid: owner_pid, metadata: %{counter: 1}}
                 {:update_metadata, :ok, %{counter: 2}}
               end)

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: owner_pid, metadata: %{counter: 2}}}
    end

    test "forbids updating if the key is already owned but the callers don't have access",
         %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      # The key is owned by "owner_pid".
      init_key(owner_pid, key, %{})

      # Now, trying to update the key from self() doesn't work because self() wasn't allowed.
      # By "doesn't work", we mean that this is inserted as a new key.
      assert {:ok, :ok} =
               NimbleOwnership.get_and_update(@server, [self()], key, fn info ->
                 assert info == nil
                 {:noop, :ok}
               end)
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
                  NimbleOwnership.get_and_update(@server, callers(), key, fn info ->
                    assert info == %{owner_pid: parent_pid, metadata: %{counter: 1}}
                    {:update_metadata, :ok, %{counter: 2}}
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

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: self(), metadata: %{counter: 2}}}
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
              NimbleOwnership.get_and_update(@server, callers(), key, fn info ->
                assert info == %{owner_pid: parent_pid, metadata: %{counter: 1}}
                {:update_metadata, :ok, %{counter: 2}}
              end)

              send(parent_pid, :done)
          end
        end)

      Process.register(lazy_pid, :lazy_pid)

      send(lazy_pid, :go)
      assert_receive :done

      assert NimbleOwnership.get_owner(@server, [self()], key) ==
               {:ok, %{owner_pid: self(), metadata: %{counter: 2}}}
    end

    test "is idempotent", %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
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

      assert :error = NimbleOwnership.get_owner(@server, [child_pid, owner_pid], key)
    end
  end

  defp callers do
    [self()] ++ Process.get(:"$callers", [])
  end

  defp init_key(owner, key, meta) do
    assert {:ok, :ok} =
             NimbleOwnership.get_and_update(@server, [], key, fn val ->
               assert val == nil
               {:set_owner, owner, :ok, meta}
             end)
  end
end
