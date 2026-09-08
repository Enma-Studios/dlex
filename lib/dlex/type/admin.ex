defmodule Dlex.Type.Admin do
  @moduledoc false

  alias Dlex.{Adapter, Query}
  alias Dlex.Api
  alias Dlex.Api.Response

  @behaviour Dlex.Type

  @impl true
  def execute(adapter, channel, {operation, request}, json_lib, opts) do
    Adapter.admin(adapter, channel, operation, request, json_lib, opts)
  end

  @impl true
  def describe(query, _opts), do: query

  @impl true
  def encode(%Query{statement: %{operation: operation, request: request}}, _vars, _opts),
    do: {operation, request}

  @impl true
  def decode(
        %Query{statement: %{operation: :run_dql}, json: json_lib},
        %Response{} = response,
        opts
      ) do
    result = decode_response(response, json_lib, opts)

    if Keyword.get(opts, :return_metadata, false) do
      %{result: result, metadata: metadata(response)}
    else
      result
    end
  end

  def decode(
        %Query{statement: %{operation: operation}},
        %Response{json: jwt},
        _opts
      )
      when operation in [:login, :relogin] and is_binary(jwt) do
    jwt
    |> Protobuf.decode(Api.Jwt)
    |> response_to_map()
  end

  def decode(
        %Query{statement: %{operation: :stream_ext_snapshot}},
        stream,
        _opts
      ),
      do: stream

  def decode(_query, response, _opts), do: response_to_map(response)

  defp decode_response(%Response{rdf: rdf, json: json}, json_lib, opts) do
    if Keyword.get(opts, :resp_format, :json) == :rdf do
      rdf || <<>>
    else
      decode_response_json(json, json_lib)
    end
  end

  defp decode_response_json(json, json_lib) when is_binary(json) and json != "" do
    json_lib.decode!(json)
  end

  defp decode_response_json(_, _), do: %{}

  defp response_to_map(response) when is_struct(response) do
    response
    |> Map.from_struct()
    |> Map.drop([:__unknown_fields__, :__protobuf__])
    |> response_to_map()
  end

  defp response_to_map(response) when is_map(response) do
    Map.new(response, fn {key, value} -> {key, response_to_map(value)} end)
  end

  defp response_to_map(response) when is_list(response),
    do: Enum.map(response, &response_to_map/1)

  defp response_to_map(response), do: response

  def metadata(%Response{latency: latency, metrics: metrics, hdrs: hdrs}) do
    %{
      latency: struct_to_map(latency),
      metrics: struct_to_map(metrics),
      headers: response_headers(hdrs)
    }
  end

  defp response_headers(headers) when is_map(headers) do
    Map.new(headers, fn
      {key, %{value: values}} -> {key, values}
      {key, values} -> {key, values}
    end)
  end

  defp response_headers(_), do: %{}

  defp struct_to_map(nil), do: nil

  defp struct_to_map(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__unknown_fields__, :__protobuf__])
  end
end
