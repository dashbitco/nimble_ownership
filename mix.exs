defmodule NimbleOwnership.MixProject do
  use Mix.Project

  def project do
    [
      app: :nimble_ownership,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev}
    ]
  end
end
