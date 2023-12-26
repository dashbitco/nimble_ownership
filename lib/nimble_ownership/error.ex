defmodule NimbleOwnership.Error do
  @moduledoc """
  Exception struct returned by `NimbleOwnership` functions.
  """

  @type t() :: %__MODULE__{
          reason: {:already_allowed, pid()}
        }

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    format_reason(reason)
  end

  defp format_reason({:already_allowed, other_owner_pid}) do
    "this PID is already allowed to access key via other owner PID #{inspect(other_owner_pid)}"
  end
end
