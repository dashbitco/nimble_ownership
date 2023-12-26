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

  @typedoc "Ownership server."
  @type server() :: GenServer.server()

  @typedoc "Arbitrary key."
  @type key() :: term()

  @typedoc "Arbitrary metadata associated with an *allowance*."
  @type metadata() :: term()

  @typedoc "Information about the owner of a key returned by `get_owner/3`."
  @type owner_info() :: %{metadata: metadata(), owner_pid: pid()}

  @typedoc false
  @type allowances() :: %{
          optional(allowed_pid :: pid()) => %{
            optional(key :: term()) => owner_info()
          }
        }

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
      raise ArgumentError, "unknown options: #{inspect(other_opts)}"
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
  @spec allow(server(), pid(), pid() | (-> pid()), key(), metadata()) ::
          :ok | {:error, NimbleOwnership.Error.t()}
  def allow(ownership_server, owner_pid, pid_to_allow, key, metadata)
      when is_pid(owner_pid) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) do
    GenServer.call(ownership_server, {:allow, owner_pid, pid_to_allow, key, metadata})
  end

  @doc """
  Retrieves the first PID in `callers` that is allowed to use `key` (on
  the given `ownership_server`).

  See `allow/5` for examples.
  """
  @spec get_owner(server(), [pid(), ...], key()) :: owner_info() | nil
  def get_owner(ownership_server, [_ | _] = callers, key) when is_list(callers) do
    GenServer.call(ownership_server, {:get_owner, callers, key})
  end

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %{allowances: %{}, deps: %{}, lazy_calls: false}}
  end

  @impl true
  def handle_call(call, from, state)

  def handle_call(
        {:allow, owner_pid, pid_to_allow, key, metadata},
        _from,
        state
      ) do
    %{owner_pid: owner_pid, metadata: metadata} =
      state.allowances[owner_pid][key] || %{owner_pid: owner_pid, metadata: metadata}

    case state.allowances[pid_to_allow][key] do
      %{owner_pid: other_owner_pid} when other_owner_pid != owner_pid ->
        error = %NimbleOwnership.Error{reason: {:already_allowed, other_owner_pid}}
        {:reply, {:error, error}, state}

      _other ->
        state =
          maybe_add_and_monitor_pid(state, owner_pid, :DOWN, fn {on, deps} ->
            {on, [{pid_to_allow, key} | deps]}
          end)

        state =
          state
          |> put_in(
            [:allowances, Access.key(pid_to_allow, %{}), key],
            %{owner_pid: owner_pid, metadata: metadata}
          )
          |> update_in([:lazy_calls], &(&1 or is_function(pid_to_allow, 0)))

        {:reply, :ok, state}
    end
  end

  def handle_call({:get_owner, callers, key}, _from, %{} = state) do
    state = revalidate_lazy_calls(state)

    reply =
      Enum.find_value(callers, nil, fn caller ->
        case state.allowances[caller][key] do
          nil ->
            nil

          %{owner_pid: owner_pid, metadata: metadata} ->
            %{owner_pid: owner_pid, metadata: metadata}
        end
      end)

    {:reply, reply, state}
  end

  @impl true
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
        # state = put_in(state.deps[pid], {on, []})
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
            {fun, mock} when is_function(fun, 0) -> {Map.get(fun_to_pids, fun, fun), mock}
            other -> other
          end)

        {pid, {fun, deps}}
      end)

    %{state | deps: deps, allowances: Map.new(allowances), lazy_calls: lazy_calls}
  end
end
