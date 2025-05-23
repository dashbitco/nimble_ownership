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
      assert {:ok, :yeah} =
               NimbleOwnership.get_and_update(@server, self(), key, fn arg ->
                 assert arg == nil
                 {:yeah, %{counter: 1}}
               end)

      assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
      assert owner_pid == self()
    end

    test "nil as metadata is ok", %{key: key} do
      assert {:ok, nil} =
               NimbleOwnership.get_and_update(@server, self(), key, fn arg ->
                 assert arg == nil
                 {nil, arg}
               end)

      assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
      assert owner_pid == self()
    end

    test "updates the metadata with the returned value from the function", %{key: key} do
      test_pid = self()
      init_key(test_pid, key, %{counter: 1})

      assert {:ok, :yeah} =
               NimbleOwnership.get_and_update(@server, test_pid, key, fn info ->
                 assert info == %{counter: 1}
                 {:yeah, %{counter: 2}}
               end)

      assert {:ok, ^test_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
      assert get_meta(test_pid, key) == %{counter: 2}
    end

    test "raises an error if the callback function returns an invalid value", %{key: key} do
      assert_raise ArgumentError, ~r"invalid return value from callback function", fn ->
        NimbleOwnership.get_and_update(@server, self(), key, fn nil -> :invalid_return end)
      end
    end

    test "returns an error if PID A allows PID X, PID B allows PID X, and PID X tries to update",
         %{key: key} do
      owner_pid1 = spawn(fn -> Process.sleep(:infinity) end)
      owner_pid2 = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid1, :"#{key}_1", 1)
      init_key(owner_pid2, :"#{key}_2", 2)

      assert :ok = NimbleOwnership.allow(@server, owner_pid1, self(), :"#{key}_1")
      assert :ok = NimbleOwnership.allow(@server, owner_pid2, self(), :"#{key}_2")

      assert {:error, error} =
               NimbleOwnership.get_and_update(@server, self(), :"#{key}_1", fn _ ->
                 {:yeah, %{}}
               end)

      assert error == %Error{reason: {:already_allowed, owner_pid1}, key: :"#{key}_1"}
      assert Exception.message(error) =~ "this PID is already allowed to access key"
    end

    test "returns an error if PID A allows PID B lazily and PID B tries to update", %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, 1)

      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 owner_pid,
                 fn -> Process.whereis(:self_name) end,
                 key
               )

      Process.register(self(), :self_name)

      assert {:error, error} =
               NimbleOwnership.get_and_update(@server, self(), key, fn _ ->
                 {:yeah, %{}}
               end)

      assert error == %Error{reason: {:already_allowed, owner_pid}, key: key}
      assert Exception.message(error) =~ "this PID is already allowed to access key"
    end

    test "can set and update keys in shared mode", %{key: key} do
      NimbleOwnership.set_mode_to_shared(@server, self())

      NimbleOwnership.get_and_update(@server, self(), key, fn value ->
        assert value == nil
        {:ok, 1}
      end)

      NimbleOwnership.get_and_update(@server, self(), key, fn value ->
        assert value == 1
        {:ok, 2}
      end)
    end

    test "supports going to shared mode and then back to private mode", %{key: key} do
      assert :ok = NimbleOwnership.set_mode_to_shared(@server, self())

      init_key(self(), key, _meta = 1)

      assert NimbleOwnership.fetch_owner(@server, [self()], key) == {:shared_owner, self()}

      assert :ok = NimbleOwnership.set_mode_to_private(@server)

      other_owner_pid1 = spawn(fn -> Process.sleep(:infinity) end)
      other_owner_pid2 = spawn(fn -> Process.sleep(:infinity) end)

      init_key(other_owner_pid1, key, _meta = :one)
      init_key(other_owner_pid2, key, _meta = :two)

      # The shared owner is still the owner of that particular key.
      assert NimbleOwnership.fetch_owner(@server, [self()], key) == {:ok, self()}

      assert NimbleOwnership.fetch_owner(@server, [other_owner_pid1], key) ==
               {:ok, other_owner_pid1}

      assert NimbleOwnership.fetch_owner(@server, [other_owner_pid2], key) ==
               {:ok, other_owner_pid2}
    end

    test "returns an error if trying to insert a new owner in shared mode", %{key: key} do
      NimbleOwnership.set_mode_to_shared(@server, self())

      task =
        Task.async(fn ->
          NimbleOwnership.get_and_update(@server, self(), key, fn _ -> {:ok, %{}} end)
        end)

      assert {:error, error} = Task.await(task)
      assert error == %Error{reason: {:not_shared_owner, self()}, key: key}
      assert Exception.message(error) =~ "is not the shared owner, so it cannot update keys"
    end
  end

  describe "fetch_owner/4" do
    test "retrieves the owner from a list of callers", %{key: key} do
      test_pid = self()

      # Initialize the key in the test process.
      assert {:ok, :yeah} =
               NimbleOwnership.get_and_update(@server, self(), key, fn arg ->
                 assert arg == nil
                 {:yeah, %{counter: 1}}
               end)

      # Make sure that if the owner is in the callers, we can fetch the key.
      task =
        Task.async(fn ->
          first_task_pid = self()

          Task.async(fn ->
            callers = [first_task_pid, test_pid]
            assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, callers, key)
            assert owner_pid == test_pid
          end)
          |> Task.await()
        end)

      Task.await(task)
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
                  assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
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
              assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
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

    test "supports lists of lazy allowed PIDs that resolve on the next upsert", %{key: key} do
      parent_pid = self()

      # Init the key.
      init_key(parent_pid, key, %{counter: 1})

      # Allow two lazy PIDs that will resolve later.
      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 self(),
                 fn ->
                   [Process.whereis(:lazy_pid_1), :not_a_pid, Process.whereis(:lazy_pid_2)]
                 end,
                 key
               )

      lazy_pid_fun =
        fn ->
          receive do
            :go ->
              assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
              assert owner_pid == parent_pid

              NimbleOwnership.get_and_update(@server, owner_pid, key, fn info ->
                assert %{counter: counter} = info
                {:ok, %{counter: counter + 1}}
              end)

              send(parent_pid, :done)
              Process.sleep(:infinity)
          end
        end

      {:ok, lazy_pid_1} = Task.start_link(lazy_pid_fun)
      Process.register(lazy_pid_1, :lazy_pid_1)
      {:ok, lazy_pid_2} = Task.start_link(lazy_pid_fun)
      Process.register(lazy_pid_2, :lazy_pid_2)

      send(lazy_pid_1, :go)
      assert_receive :done

      assert NimbleOwnership.fetch_owner(@server, [lazy_pid_1], key) == {:ok, self()}
      assert get_meta(self(), key) == %{counter: 2}

      send(lazy_pid_2, :go)
      assert_receive :done

      assert NimbleOwnership.fetch_owner(@server, [lazy_pid_2], key) == {:ok, self()}
      assert get_meta(self(), key) == %{counter: 3}
    end

    test "properly merges lazy allowed PIDs that resolve on the next upsert", %{key: key} do
      parent_pid = self()

      parent_process_fun = fn counter ->
        fn ->
          # Init the key
          key = "#{counter} → #{key}"
          init_key(self(), key, %{counter: 1})

          # Allow two lazy PID that will resolve later
          assert :ok =
                   NimbleOwnership.allow(
                     @server,
                     self(),
                     fn -> Process.whereis(:lazy_pid) end,
                     key
                   )

          receive do
            {:go, lazy_pid} ->
              send(lazy_pid, {:go, self(), key})
              assert_receive :done

              assert NimbleOwnership.fetch_owner(@server, [self()], key) == {:ok, self()}
              assert get_meta(self(), key) == %{counter: 2}

              send(parent_pid, :parent_process_done)
          end
        end
      end

      {:ok, pid_1} = Task.start_link(parent_process_fun.(1))
      {:ok, pid_2} = Task.start_link(parent_process_fun.(2))

      lazy_process_fun = fn ->
        for _ <- 1..2 do
          receive do
            {:go, parent_pid, key} ->
              assert {:ok, owner_pid} = NimbleOwnership.fetch_owner(@server, [self()], key)
              assert owner_pid == parent_pid

              NimbleOwnership.get_and_update(@server, owner_pid, key, fn info ->
                assert info == %{counter: 1}
                {:ok, %{counter: 2}}
              end)

              send(parent_pid, :done)
          end
        end
      end

      {:ok, lazy_pid} = Task.start_link(lazy_process_fun)
      Process.register(lazy_pid, :lazy_pid)

      send(pid_1, {:go, lazy_pid})
      send(pid_2, {:go, lazy_pid})

      assert_receive :parent_process_done
      assert_receive :parent_process_done
    end

    test "ignores lazy PIDs that don't actually resolve to a PID", %{key: key} do
      owner_pid = self()

      # Init the key.
      init_key(owner_pid, key, %{counter: 1})

      # Allow a lazy PID that will resolve later to nil.
      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 owner_pid,
                 fn -> Process.whereis(:"what_pid?!") end,
                 key
               )

      assert NimbleOwnership.fetch_owner(@server, [owner_pid], key) == {:ok, owner_pid}
    end

    test "does not resolve irrelevant lazy PIDs", %{key: key} do
      parent_pid = self()

      key2 = :"#{key}-2"

      # Init the key.
      init_key(parent_pid, key, %{counter: 1})
      init_key(parent_pid, key2, %{})

      # Allow a lazy PID that will resolve later.
      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 self(),
                 fn -> Process.whereis(:lazy_pid) end,
                 key
               )

      # Allow a lazy PID that will never resolver
      assert :ok =
               NimbleOwnership.allow(
                 @server,
                 self(),
                 fn -> raise "Too eager!" end,
                 key2
               )

      {:ok, lazy_pid} =
        Task.start_link(fn ->
          Process.sleep(:infinity)
        end)

      Process.register(lazy_pid, :lazy_pid)

      assert NimbleOwnership.fetch_owner(@server, [lazy_pid], key) == {:ok, self()}
    end

    test "is idempotent", %{key: key} do
      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key)
    end

    test "can be used to allow different keys", %{key: key} do
      key1 = :"#{key}_1"
      key2 = :"#{key}_2"

      owner_pid = spawn(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key1, %{})
      init_key(owner_pid, key2, %{})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key1)
      assert :ok = NimbleOwnership.allow(@server, owner_pid, self(), key2)
    end

    test "returns an error if called in shared mode", %{key: key} do
      NimbleOwnership.set_mode_to_shared(@server, self())

      assert {:error, error} = NimbleOwnership.allow(@server, self(), self(), key)
      assert error == %Error{reason: :cant_allow_in_shared_mode, key: key}
      assert Exception.message(error) =~ "cannot allow PIDs in shared mode"
    end

    test "returns an error if the PID to allow is already an owner", %{key: key} do
      init_key(self(), key, :meta)
      assert {:error, error} = NimbleOwnership.allow(@server, self(), self(), key)
      assert error == %Error{reason: :already_an_owner, key: key}
      assert Exception.message(error) =~ "this PID is already an owner of key"
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

    test "returns all the owned keys + metadata for the owner PID in shared mode", %{key: key} do
      NimbleOwnership.set_mode_to_shared(@server, self())
      owner_pid = self()

      init_key(owner_pid, :"#{key}_1", 1)
      init_key(owner_pid, :"#{key}_2", 2)

      expected_result = %{:"#{key}_1" => 1, :"#{key}_2" => 2}

      assert NimbleOwnership.get_owned(@server, owner_pid) == expected_result

      # Also works from a different PID.
      task = Task.async(fn -> NimbleOwnership.get_owned(@server, owner_pid) end)
      assert Task.await(task) == expected_result
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

    test "if a child shuts down, the deps of that child are not cleaned up (because that child is not the original owner)",
         %{key: key} do
      {owner_pid, _owner_monitor_ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      {child_pid1, child_monitor_ref1} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      {child_pid2, _child_monitor_ref2} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{counter: 1})

      assert :ok = NimbleOwnership.allow(@server, owner_pid, child_pid1, key)
      assert :ok = NimbleOwnership.allow(@server, child_pid1, child_pid2, key)

      Process.exit(child_pid1, :kill)
      assert_receive {:DOWN, ^child_monitor_ref1, _, _, _}

      assert :error = NimbleOwnership.fetch_owner(@server, [child_pid1], key)
      assert {:ok, ^owner_pid} = NimbleOwnership.fetch_owner(@server, [child_pid2], key)
    end
  end

  describe "set_owner_to_manual_cleanup/2" do
    test "sets a PID to manual cleanup", %{key: key} do
      {owner_pid, monitor_ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      init_key(owner_pid, key, %{counter: 1})

      assert :ok = NimbleOwnership.set_owner_to_manual_cleanup(@server, owner_pid)

      Process.exit(owner_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, _, _, _}

      assert {:ok, ^owner_pid} = NimbleOwnership.fetch_owner(@server, [owner_pid], key)
      assert NimbleOwnership.get_owned(@server, owner_pid) == %{key => %{counter: 1}}

      assert :ok = NimbleOwnership.cleanup_owner(@server, owner_pid)
      assert :error = NimbleOwnership.fetch_owner(@server, [owner_pid], key)
      assert NimbleOwnership.get_owned(@server, owner_pid) == nil
    end

    test "works if the PID is not an owner" do
      assert :ok = NimbleOwnership.set_owner_to_manual_cleanup(@server, self())
      assert NimbleOwnership.get_owned(@server, self()) == nil
    end
  end

  defp init_key(owner, key, meta) do
    assert {:ok, :ok} =
             NimbleOwnership.get_and_update(@server, owner, key, fn nil -> {:ok, meta} end)
  end

  defp get_meta(owner, key) do
    assert {:ok, meta} =
             NimbleOwnership.get_and_update(@server, owner, key, fn meta ->
               assert meta != nil
               {meta, meta}
             end)

    meta
  end
end
