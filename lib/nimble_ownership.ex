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
    res(["Resource (with associated metadata)"])

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
  if a PID can access the given key through `fetch_owner/3`.

  ### Metadata

  You can store arbitrary metadata (`t:metadata/0`) alongside each **owned resource**.
  This metadata is returned together with the owner PID when you call `fetch_owner/3`.

  ## Modes

  The ownership server can be in one of two modes:

    * **private** (the default): in this mode, you can only allow access to a key through
      the owner PID or PIDs that are already allowed to access the key. You can allow PIDs
      through `allow/4`. This mode is useful when you want to track ownership of resources
      in concurrent environments (such as in a test suite).

    * **shared**: in this mode, there is only one *global owner PID* that owns all the keys
      in the ownership server. Any other PID can read the metadata associated with any key,
      but it cannot update the metadata (only the global owner can).

  """

  use GenServer

  alias NimbleOwnership.Error

  @typedoc "Ownership server."
  @type server() :: GenServer.server()

  @typedoc "Arbitrary key."
  @type key() :: term()

  @typedoc "Arbitrary metadata associated with an owned `t:key/0`."
  @type metadata() :: term()

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

  This function returns an error when `pid_to_allow` is already allowed to use
  `key` via **another owner PID** that is not `owner_pid`.

  ## Examples

      iex> pid = spawn(fn -> Process.sleep(:infinity) end)
      iex> {:ok, server} = NimbleOwnership.start_link()
      iex> NimbleOwnership.get_and_update(server, self(), :my_key, fn _ -> {:updated, _meta = %{}} end)
      {:ok, :updated}
      iex> NimbleOwnership.allow(server, self(), pid, :my_key)
      :ok
      iex> NimbleOwnership.fetch_owner(server, [pid], :my_key)
      {:ok, self()}

  """
  @spec allow(server(), pid(), pid() | (-> pid()), key()) ::
          :ok | {:error, Error.t()}
  def allow(ownership_server, owner_pid, pid_to_allow, key)
      when is_pid(owner_pid) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) do
    GenServer.call(ownership_server, {:allow, owner_pid, pid_to_allow, key})
  end

  @doc """
  Accesses `key` (owned by `owner_pid`) or initializes the ownership.

  Use this function for these purposes:

    * to initialize the ownership of a key
    * to update the metadata associated with a key

  ## Usage

  When `owner_pid` doesn't own `key`, the value passed to `fun` will be `nil`. Otherwise,
  it will be the current metadata associated with `key` under the owner `owner_pid`.

  `fun` must return `{get_value, new_meta}`. `owner_pid` will start owning
  `key` and `new_meta` will be the metadata associated with that ownership, or,
  in case `owner_pid` already owned `key`, then the metadata is updated to `new_meta`.

  If this function is successful, the return value is `{:ok, get_value}` where `get_value`
  is the value returned by `fun` in its return tuple. Otherwise, the return value is
  `{:error, reason}` (see also `NimbleOwnership.Error`).

  ### Updating Metadata from an Allowed Process

  If you don't directly have access to the owner PID, but you want to update the metadata
  associated with the owner PID and `key` *from an allowed process*, do this instead:

    1. Fetch the owner of `key` through `fetch_owner/3`.
    2. Call `get_and_update/4` with the owner PID as `owner_pid`, passing in a callback
       function that returns the new metadata.

  ### Shared Mode

  When the ownership server is set to **shared mode**, you can only call this function
  with `owner_pid` set to the global owner PID. See [the module documentation](#module-modes).
  """
  @spec get_and_update(server(), pid(), key(), fun) :: {:ok, get_value} | {:error, Error.t()}
        when fun: (nil | metadata() -> {get_value, updated_metadata :: metadata()}),
             get_value: term()
  def get_and_update(ownership_server, owner_pid, key, fun)
      when is_pid(owner_pid) and is_function(fun, 1) do
    case GenServer.call(ownership_server, {:get_and_update, owner_pid, key, fun}) do
      {:ok, get_value} -> {:ok, get_value}
      {:error, %Error{} = error} -> {:error, error}
      {:__raise__, error} when is_exception(error) -> raise error
    end
  end

  @doc """
  Gets the owner of `key` through one of the `callers`.

  If one of the `callers` owns `key` or is allowed access to `key`,
  then this function returns `{:ok, {owner_pid, metadata}}` where `metadata` is the
  metadata associated with the `key` under the owner.

  If none of the callers owns `key` or is allowed access to `key`, then this function
  returns `{:error, reason}`.

  For usage examples, see `allow/4`.
  """
  @spec fetch_owner(server(), [pid(), ...], key()) :: {:ok, owner :: pid()} | {:error, reason}
        when reason: Error.t()
  def fetch_owner(ownership_server, [_ | _] = callers, key) do
    GenServer.call(ownership_server, {:fetch_owner, callers, key})
  end

  @doc """
  Gets all the keys owned by `owner_pid` with all their associated metadata.

  If `owner_pid` doesn't own any keys, then this function returns `default`.

  ## Examples

      iex> owner = spawn(fn -> Process.sleep(:infinity) end)
      iex> {:ok, server} = NimbleOwnership.start_link()
      iex> NimbleOwnership.get_and_update(server, owner, :my_key1, fn _ -> {:ok, 1} end)
      iex> NimbleOwnership.get_and_update(server, owner, :my_key2, fn _ -> {:ok, 2} end)
      iex> NimbleOwnership.get_owned(server, owner)
      %{my_key1: 1, my_key2: 2}
      iex> NimbleOwnership.get_owned(server, self(), :default)
      :default

  """
  @spec get_owned(server(), pid(), default) :: %{key() => metadata()} | default
        when default: term()
  def get_owned(ownership_server, owner_pid, default \\ nil) when is_pid(owner_pid) do
    GenServer.call(ownership_server, {:get_owned, owner_pid, default})
  end

  @doc """
  Sets the ownership server to *private mode*.

  See [the module documentation](#module-modes) for more information.
  """
  @spec set_mode_to_private(server()) :: :ok
  def set_mode_to_private(ownership_server) do
    GenServer.call(ownership_server, {:set_mode, :private})
  end

  @doc """
  Sets the ownership server to *shared mode* and sets `global_owner` as the global owner.

  See [the module documentation](#module-modes) for more information.
  """
  @spec set_mode_to_shared(server(), pid()) :: :ok
  def set_mode_to_shared(ownership_server, global_owner) when is_pid(global_owner) do
    GenServer.call(ownership_server, {:set_mode, {:shared, global_owner}})
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
            mode: :private,
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

  def handle_call(
        {:allow, _pid_with_access, _pid_to_allow, key},
        _from,
        %__MODULE__{mode: {:shared, _global_owner}} = state
      ) do
    error = %Error{key: key, reason: :cant_allow_in_shared_mode}
    {:reply, {:error, error}, state}
  end

  def handle_call(
        {:allow, pid_with_access, pid_to_allow, key},
        _from,
        %__MODULE__{mode: :private} = state
      ) do
    if state.owners[pid_to_allow][key] do
      error = %Error{key: key, reason: :already_an_owner}
      throw({:reply, {:error, error}, state})
    end

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

  def handle_call({:get_and_update, owner_pid, key, fun}, _from, %__MODULE__{} = state) do
    state = revalidate_lazy_calls(state)

    case state.mode do
      {:shared, global_owner_pid} when global_owner_pid != owner_pid ->
        error = %Error{key: key, reason: {:not_global_owner, global_owner_pid}}
        throw({:reply, {:error, error}, state})

      _ ->
        :ok
    end

    if other_owner = state.allowances[owner_pid][key] do
      throw({:reply, {:error, %Error{key: key, reason: {:already_allowed, other_owner}}}, state})
    end

    case fun.(_meta_or_nil = state.owners[owner_pid][key]) do
      {get_value, new_meta} ->
        state = put_in(state, [Access.key!(:owners), Access.key(owner_pid, %{}), key], new_meta)

        # We should also monitor the new owner, if it hasn't already been monitored. That
        # can happen if that owner is already the owner of another key.
        state =
          if state.monitors[owner_pid] do
            state
          else
            ref = Process.monitor(owner_pid)
            put_in(state.monitors[owner_pid], ref)
          end

        {:reply, {:ok, get_value}, state}

      other ->
        message = """
        invalid return value from callback function. Expected nil or a tuple of the form \
        {get_value, update_value} (see the function's @spec), instead got: #{inspect(other)}\
        """

        {:reply, {:__raise__, %ArgumentError{message: message}}, state}
    end
  end

  def handle_call(
        {:fetch_owner, _callers, _key},
        _from,
        %__MODULE__{mode: {:shared, global_owner_pid}} = state
      ) do
    {:reply, {:ok, global_owner_pid}, state}
  end

  def handle_call({:fetch_owner, callers, key}, _from, %__MODULE__{mode: :private} = state) do
    state = revalidate_lazy_calls(state)

    Enum.find_value(callers, {:reply, :error, state}, fn caller ->
      cond do
        owner_pid = state.allowances[caller][key] -> {:reply, {:ok, owner_pid}, state}
        _meta = state.owners[caller][key] -> {:reply, {:ok, caller}, state}
        true -> nil
      end
    end)
  end

  def handle_call({:get_owned, owner_pid, default}, _from, %__MODULE__{} = state) do
    {:reply, state.owners[owner_pid] || default, state}
  end

  def handle_call({:set_mode, {:shared, global_owner_pid}}, _from, %__MODULE__{} = state) do
    state = maybe_add_and_monitor_pid(state, global_owner_pid, :DOWN, & &1)
    state = %__MODULE__{state | mode: {:shared, global_owner_pid}}
    {:reply, :ok, state}
  end

  def handle_call({:set_mode, :private}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %__MODULE__{state | mode: :private}}
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

    %__MODULE__{state | deps: deps, allowances: Map.new(allowances), lazy_calls: lazy_calls}
  end
end
