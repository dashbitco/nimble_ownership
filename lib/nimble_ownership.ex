defmodule NimbleOwnership do
  @moduledoc """
  Module that allows you to manage ownership of resources across processes.

  The idea is that you can track ownership of terms (keys) across processes,
  and allow processes to use a key through processes that are already allowed.

  ```mermaid
  flowchart LR
    pidA["Process A"]
    pidB["Process B"]
    pidC["Process C"]
    res(["Resource"])

    pidA -->|Owns| res
    pidA -->|Allows| pidB
    pidB -->|Can access| res
    pidB -->|Allows| pidC
    pidC -->|Can access| res
  ```

  A typical use case for such a module is tracking resource ownership across processes
  in order to isolate access to resources in **test suites**. For example, the
  [Mox](https://hexdocs.pm/mox/Mox.html) library uses this module to track ownership
  of mocks across processes (in shared mode).

  ## Usage

  To track ownership of resources, you need to start a `NimbleOwnership` server (a process),
  through `start_link/1` or `child_spec/1`.

  Then, you can allow a process access to a key through `allow/5`. You can then check
  if a PID can access the given key through `get_owner/3`.

  ### Metadata

  You can store arbitrary metadata (`t:metadata/0`) alongside each "allowance", that is,
  alongside the relationship between a process and a key. This metadata is returned
  together with the owner PID when you call `get_owner/3`.
  """

  use GenServer

  alias NimbleOwnership.Error

  @typedoc "Ownership server."
  @type server() :: GenServer.server()

  @typedoc "Arbitrary key."
  @type key() :: term()

  @typedoc "Arbitrary metadata associated with an *allowance*."
  @type metadata() :: term()

  @typedoc "Information about the owner of a key returned by `get_owner/3`."
  @type owner_info() :: %{metadata: metadata(), owner_pid: pid()}

  @genserver_opts [
    :name,
    :timeout,
    :debug,
    :spawn_opt,
    :hibernate_after
  ]

  @doc """
  Starts an ownership server.

  ## Options

  This function supports all the options supported by `GenServer.start_link/3`, namely:

  #{Enum.map_join(@genserver_opts, "\n", &"  * `#{inspect(&1)}`")}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
    {genserver_opts, other_opts} = Keyword.split(options, @genserver_opts)

    if other_opts != [] do
      raise ArgumentError, "unknown options: #{inspect(Keyword.keys(other_opts))}"
    end

    GenServer.start_link(__MODULE__, [], genserver_opts)
  end

  @doc """
  Allows `pid_to_allow` to use `key` through `owner_pid` (on the given `ownership_server`).

  Use this function when `owner_pid` is allowed access to `key`, and you want
  to also allow `pid_to_allow` to use `key`.

  `metadata` is an arbitrary term that you can use to store additional information
  about the allowance. It is returned by `get_owner/3`.

  This function returns an error when `pid_to_allow` is already allowed to use
  `key` via **another owner PID** that is not `owner_pid`.

  ## Examples

      iex> pid = spawn(fn -> Process.sleep(:infinity) end)
      iex> {:ok, server} = NimbleOwnership.start_link()
      iex> NimbleOwnership.allow(server, self(), pid, :my_key, %{counter: 1})
      :ok
      iex> NimbleOwnership.get_owner(server, [pid], :my_key)
      %{owner_pid: self(), metadata: %{counter: 1}}

  """
  @spec allow(server(), pid(), pid() | (-> pid()), key()) ::
          :ok | {:error, Error.t()}
  def allow(ownership_server, owner_pid, pid_to_allow, key)
      when is_pid(owner_pid) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) do
    GenServer.call(ownership_server, {:allow, owner_pid, pid_to_allow, key})
  end

  @doc """
  TODO
  """
  @spec get_and_update(server(), [pid()], key(), fun) :: {:ok, reply} | {:error, Error.t()}
        when fun:
               (nil -> {:set_owner, pid(), reply, metadata()} | {:noop, reply})
               | (owner_info() -> {:update_metadata, reply, metadata()} | {:noop, reply}),
             reply: term()
  def get_and_update(ownership_server, callers, key, fun)
      when is_list(callers) and is_function(fun, 1) do
    GenServer.call(ownership_server, {:get_and_update, callers, key, fun})
  end

  @doc """
  TODO
  """
  @spec get_owner(server(), [pid(), ...], key()) :: {:ok, owner_info()} | {:error, reason}
        when reason: Error.t()
  def get_owner(ownership_server, [_ | _] = callers, key) do
    GenServer.call(ownership_server, {:get_owner, callers, key})
  end

  ## State

  # This is here only for documentation and for understanding the shape of the state.
  @typedoc false
  @type t() :: %__MODULE__{
          owners: %{
            optional(owner_pid :: pid()) => %{
              optional(key :: term()) => metadata()
            }
          },
          allowances: %{
            optional(allowed_pid :: pid()) => %{optional(key()) => owner_pid :: pid()}
          },
          lazy_calls: boolean(),
          deps: %{
            optional(pid() | (-> pid())) => {:DOWN, :process, pid(), term()}
          }
        }

  defstruct allowances: %{},
            deps: %{},
            lazy_calls: false,
            owners: %{},
            monitors: %{}

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(call, from, state)

  def handle_call({:allow, pid_with_access, pid_to_allow, key}, _from, %__MODULE__{} = state) do
    owner_pid =
      cond do
        owner_pid = state.allowances[pid_with_access][key] ->
          owner_pid

        _meta = state.owners[pid_with_access][key] ->
          pid_with_access

        true ->
          throw({:reply, {:error, %Error{key: key, reason: :not_allowed}}, state})
      end

    case state.allowances[pid_to_allow][key] do
      # There's already another owner PID that is allowing "pid_to_allow" to use "key".
      other_owner_pid when is_pid(other_owner_pid) and other_owner_pid != owner_pid ->
        error = %Error{key: key, reason: {:already_allowed, other_owner_pid}}
        {:reply, {:error, error}, state}

      # "pid_to_allow" is already allowed access to "key" through the same "owner_pid",
      # so this is a no-op.
      ^owner_pid ->
        {:reply, :ok, state}

      nil ->
        state =
          maybe_add_and_monitor_pid(state, owner_pid, :DOWN, fn {on, deps} ->
            {on, [{pid_to_allow, key} | deps]}
          end)

        state =
          state
          |> put_in([Access.key!(:allowances), Access.key(pid_to_allow, %{}), key], owner_pid)
          |> update_in([Access.key!(:lazy_calls)], &(&1 or is_function(pid_to_allow, 0)))

        {:reply, :ok, state}
    end
  end

  def handle_call({:get_and_update, callers, key, fun}, _from, %__MODULE__{} = state) do
    state = revalidate_lazy_calls(state)

    # First, we find the owner PID through the callers. Either we do that through the allowances
    # (one of the callers is allowed to access "key"), or one of the callers is the actual owner
    # of "key".
    owner_pid_through_callers =
      Enum.find_value(callers, nil, fn caller ->
        cond do
          owner = state.allowances[caller][key] -> owner
          _meta = state.owners[caller][key] -> caller
          true -> nil
        end
      end)

    cond do
      # There is already an existing owner for "key" that we found through the allowances
      # for one of the callers. This means that we can update the metadata, because the
      # caller is allowed to access "key".
      meta = state.owners[owner_pid_through_callers][key] ->
        case fun.(%{owner_pid: owner_pid_through_callers, metadata: meta}) do
          {:update_metadata, reply, new_meta} ->
            state = put_in(state.owners[owner_pid_through_callers][key], new_meta)
            {:reply, {:ok, reply}, state}

          {:noop, reply} ->
            {:reply, {:ok, reply}, state}

          {:set_owner, _new_pid, _reply, _meta} ->
            error = %Error{key: key, reason: {:cannot_reset_owner, owner_pid_through_callers}}
            {:reply, {:error, error}, state}
        end

      # There is no existing owner for "key", so we can (possibly) initialize it through "fun".
      true ->
        case fun.(nil) do
          {:set_owner, owner, reply, meta} ->
            state = put_in(state, [Access.key!(:owners), Access.key(owner, %{}), key], meta)

            # We should also monitor the new owner, if it hasn't already been monitored. That
            # can happen if that owner is already the owner of another key.
            state =
              if state.monitors[owner] do
                state
              else
                ref = Process.monitor(owner)
                put_in(state.monitors[owner], ref)
              end

            {:reply, {:ok, reply}, state}

          {:update_metadata, _reply, _meta} ->
            error = %Error{key: key, reason: :cannot_update_metadata_on_non_existing}
            {:reply, {:error, error}, state}

          {:noop, reply} ->
            {:reply, {:ok, reply}, state}
        end
    end
  end

  def handle_call({:get_owner, callers, key}, _from, %__MODULE__{} = state) do
    state = revalidate_lazy_calls(state)

    Enum.find_value(callers, {:reply, :error, state}, fn caller ->
      cond do
        owner_pid = state.allowances[caller][key] ->
          meta = state.owners[owner_pid][key]
          {:reply, {:ok, %{owner_pid: owner_pid, metadata: meta}}, state}

        meta = state.owners[caller][key] ->
          {:reply, {:ok, %{owner_pid: caller, metadata: meta}}, state}

        true ->
          nil
      end
    end)
  end

  @impl true
  def handle_info(msg, state)

  # An owner went down, so we need to clean up all of its allowances as well as all its keys.
  def handle_info({:DOWN, _, _, down_pid, _}, state) when is_map_key(state.owners, down_pid) do
    {_, state} = pop_in(state.owners[down_pid])

    allowances =
      Enum.reduce(state.allowances, state.allowances, fn {pid, allowances}, acc ->
        new_allowances =
          for {key, owner_pid} <- allowances,
              owner_pid != down_pid,
              into: %{},
              do: {key, owner_pid}

        Map.put(acc, pid, new_allowances)
      end)

    state = put_in(state.allowances, allowances)

    {:noreply, state}
  end

  def handle_info({:DOWN, _, _, down_pid, _}, state) do
    state =
      case state.deps do
        %{^down_pid => {:DOWN, _}} ->
          {{_on, deps}, state} = pop_in(state.deps[down_pid])
          {_keys_and_values, state} = pop_in(state.allowances[down_pid])

          Enum.reduce(deps, state, fn {pid, key}, acc ->
            acc.allowances[pid][key] |> pop_in() |> elem(1)
          end)

        %{} ->
          state
      end

    {:noreply, state}
  end

  ## Helpers

  defp maybe_add_and_monitor_pid(state, pid, on, fun) do
    case state.deps do
      %{^pid => entry} ->
        put_in(state.deps[pid], fun.(entry))

      _ ->
        Process.monitor(pid)
        state = put_in(state.deps[pid], fun.({on, []}))
        state
    end
  end

  defp revalidate_lazy_calls(state) do
    state.allowances
    |> Enum.reduce({[], [], false}, fn
      {key, value}, {result, resolved, unresolved} when is_function(key, 0) ->
        case key.() do
          pid when is_pid(pid) ->
            {[{pid, value} | result], [{key, pid} | resolved], unresolved}

          _ ->
            {[{key, value} | result], resolved, true}
        end

      kv, {result, resolved, unresolved} ->
        {[kv | result], resolved, unresolved}
    end)
    |> fix_resolved(state)
  end

  defp fix_resolved({_, [], _}, state), do: state

  defp fix_resolved({allowances, fun_to_pids, lazy_calls}, state) do
    fun_to_pids = Map.new(fun_to_pids)

    deps =
      Map.new(state.deps, fn {pid, {fun, deps}} ->
        deps =
          Enum.map(deps, fn
            {fun, key} when is_function(fun, 0) -> {Map.get(fun_to_pids, fun, fun), key}
            other -> other
          end)

        {pid, {fun, deps}}
      end)

    %{state | deps: deps, allowances: Map.new(allowances), lazy_calls: lazy_calls}
  end
end
