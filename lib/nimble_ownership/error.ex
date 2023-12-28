defmodule NimbleOwnership.Error do
  @moduledoc """
  Exception struct returned by `NimbleOwnership` functions.
  """

  @type t() :: %__MODULE__{
          reason:
            {:already_allowed, pid()}
            | {:cannot_reset_owner, pid()}
            | :cannot_update_metadata_on_non_existing
            | :not_allowed,
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

  defp format_reason(key, :cannot_update_metadata_on_non_existing) do
    """
    cannot return a :update_metadata tuple for key #{inspect(key)} because it's not owned \
    by the given PID. Instead, return a :set_owner tuple\
    """
  end

  defp format_reason(key, {:cannot_reset_owner, owner_pid}) do
    """
    cannot return a :set_owner tuple for key #{inspect(key)} because it's already \
    owned by PID #{inspect(owner_pid)}\
    """
  end
end
