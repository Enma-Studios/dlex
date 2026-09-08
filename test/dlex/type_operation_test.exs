defmodule Dlex.TypeOperationTest do
  use ExUnit.Case

  alias Dlex.{Query, Type, Utils}

  test "encodes fulltext and HNSW schema indexes" do
    schema = [
      %{"predicate" => "body", "type" => "string", "index" => true, "tokenizer" => ["fulltext"]},
      %{
        "predicate" => "embedding",
        "type" => "float32vector",
        "index" => true,
        "tokenizer" => ["hnsw(metric:\"cosine\")"]
      }
    ]

    assert Dlex.Type.Operation.encode_schema(schema) ==
             "body: string @index(fulltext) .\nembedding: float32vector @index(hnsw(metric:\"cosine\")) ."
  end

  test "encodes float32vector query variables as DQL vector literals" do
    assert %{"$vec" => "[1.0, 0.0]"} = Utils.encode_vars(%{"$vec" => [1.0, 0.0]})

    request =
      Type.encode(
        %Query{
          type: Dlex.Type.Query,
          statement: "query q($vec: float32vector) { q(func: has(x)) { uid } }"
        },
        %{"$vec" => [1.0, 0.0]},
        []
      )

    assert request.vars == %{"$vec" => "[1.0, 0.0]"}
  end

  test "encodes all alter operation controls" do
    query =
      Type.describe(
        %Query{
          type: Dlex.Type.Operation,
          statement: %{drop_op: :data, drop_value: "", run_in_background: true}
        },
        []
      )

    request = Type.encode(query, %{}, [])

    assert request.drop_op == :DATA
    assert request.run_in_background
    assert request.drop_all == false
    assert request.drop_attr == ""
  end
end
