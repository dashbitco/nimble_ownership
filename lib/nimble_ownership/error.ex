defmodule NimbleOwnership.Error do
  @moduledoc """
  Exception struct returned by `NimbleOwnership` functions.
  """

  @type t() :: %__MODULE__{
          reason: {:already_allowed, pid()} | :not_allowed | :already_an_owner,
          key: NimbleOwnership.key()
        }

  defexception [:reason, :key]

  @impl true
  def message(%__MODULE__{key: key, reason: reason}) do
    format_reason(key, reason)
  end

  ## Helpers

  defp format_reason(key, {:already_allowed, other_owner_pid}) do
    "this PID is already allowed to access key #{inspect(key)} via other owner PID #{inspect(other_owner_pid)}"
  end

  defp format_reason(key, :not_allowed) do
    "this PID is not allowed to access key #{inspect(key)}"
  end

  defp format_reason(key, :already_an_owner) do
    "this PID is already an owner of key #{inspect(key)}"
  end
end
