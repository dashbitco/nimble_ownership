defmodule NimbleOwnership do
  @moduledoc """
  TODO
  """

  use GenServer

  @type server() :: GenServer.server()
  @type key() :: term()
  @type metadata() :: term()
  @type owner_info() :: %{metadata: metadata(), owner_pid: pid()}

  @typedoc false
  @type allowances() :: %{
          optional(allowed_pid :: pid()) => %{
            optional(key :: term()) => owner_info()
          }
        }

  @doc """
  Starts an ownership server.

  ## Options

  This function supports all the options supported by `GenServer.start_link/3`, namely:

    * `:name`
    * `:timeout`
    * `:debug`
    * `:spawn_opt`
    * `:hibernate_after`

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @doc """
  Allows `pid_to_allow` to use `key` through `owner_pid` (on the given `ownership_server`).

  Use this function when `owner_pid` is allowed access to `key`, and you want
  to also allow `pid_to_allow` to use `key`.

  `metadata` is an arbitrary term that you can use to store additional information
  about the allowance. It is returned by `get_owner/3`.

  This function returns an error when `pid_to_allow` is already allowed to use
  `key` via **another owner PID** that is not `owner_pid`.
  """
  @spec allow(server(), pid(), pid() | (-> pid()), key(), metadata()) ::
          :ok | {:error, reason :: term()}
  def allow(ownership_server, owner_pid, pid_to_allow, key, metadata)
      when is_pid(owner_pid) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) do
    GenServer.call(ownership_server, {:allow, owner_pid, pid_to_allow, key, metadata})
  end

  @doc """
  Retrieves the first PID in `callers` that is allowed to use `key` (on
  the given `ownership_server`).
  """
  @spec get_owner(server(), [pid(), ...], key()) :: owner_info() | nil
  def get_owner(ownership_server, [_ | _] = callers, key) when is_list(callers) do
    GenServer.call(ownership_server, {:get_owner, callers, key})
  end

  ## Callbacks

  @impl true
  def init(:ok) do
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
        {:reply, {:error, {:already_allowed, other_owner_pid}}, state}

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
