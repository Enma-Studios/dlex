defmodule Dlex.Type.Query do
  @moduledoc false

  alias Dlex.{Adapter, Query, Utils}
  alias Dlex.Api.{Request, Response, TxnContext}
  alias Dlex.Type.Admin

  @behaviour Dlex.Type

  @impl true
  def execute(adapter, channel, request, json_lib, opts) do
    Adapter.query(adapter, channel, request, json_lib, opts)
  end

  @impl true
  def describe(query, _opts), do: query

  @impl true
  def encode(%Query{statement: statement}, vars, opts) do
    struct(Request,
      query: IO.iodata_to_binary(statement),
      vars: Utils.encode_vars(vars),
      read_only: Keyword.get(opts, :read_only, false),
      best_effort: Keyword.get(opts, :best_effort, false),
      resp_format: response_format(Keyword.get(opts, :resp_format, :json))
    )
  end

  @impl true
  def decode(%{json: json_lib}, %Response{txn: %TxnContext{aborted: false}} = response, opts) do
    result = decode_response(response, json_lib, opts)

    if Keyword.get(opts, :return_metadata, false) do
      %{result: result, metadata: Admin.metadata(response)}
    else
      result
    end
  end

  defp decode_response(%Response{rdf: rdf, json: json}, json_lib, opts) do
    if Keyword.get(opts, :resp_format, :json) == :rdf do
      rdf || <<>>
    else
      cond do
        is_binary(json) and json != "" -> json_lib.decode!(json)
        is_map(json) -> json
        true -> %{}
      end
    end
  end

  defp response_format(:rdf), do: :RDF
  defp response_format(:json), do: :JSON
  defp response_format(:RDF), do: :RDF
  defp response_format(:JSON), do: :JSON
end
