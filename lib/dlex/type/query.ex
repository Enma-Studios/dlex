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
  def encode(
        %Query{
          statement: statement,
          read_only: query_read_only?,
          best_effort: query_best_effort?,
          txn_context: txn_context
        },
        vars,
        opts
      ) do
    best_effort? = query_best_effort? or Keyword.get(opts, :best_effort, false)

    struct(Request,
      start_ts: transaction_start_ts(txn_context),
      query: IO.iodata_to_binary(statement),
      vars: Utils.encode_vars(vars),
      read_only: query_read_only? or Keyword.get(opts, :read_only, false) or best_effort?,
      best_effort: best_effort?,
      hash: transaction_hash(txn_context),
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

  defp transaction_hash(%{hash: hash}), do: hash
  defp transaction_hash(_), do: ""

  defp transaction_start_ts(%{start_ts: start_ts}), do: start_ts
  defp transaction_start_ts(_), do: 0
end
