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

  test "propagates transaction hashes on query and mutation requests" do
    txn = %Dlex.Api.TxnContext{start_ts: 42, hash: "txn-hash"}

    query_request =
      Type.encode(
        %Query{
          type: Dlex.Type.Query,
          statement: "{node(func: has(name)) {uid}}",
          txn_context: txn
        },
        %{},
        []
      )

    mutation_request =
      Type.encode(
        %Query{
          type: Dlex.Type.Mutation,
          statement: [%{set: "_:node <name> \"value\" ."}],
          query: "",
          txn_context: txn
        },
        %{},
        []
      )

    assert query_request.start_ts == 42
    assert query_request.hash == "txn-hash"
    assert mutation_request.start_ts == 42
    assert mutation_request.hash == "txn-hash"
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

  test "encodes structured NQuad mutations and facets" do
    nquad =
      Dlex.NQuad.uid("0x1", "friend", "0x2", facets: [Dlex.NQuad.boolean_facet("close", true)])

    request =
      Type.encode(
        %Query{
          type: Dlex.Type.Mutation,
          statement: [%{set: [nquad]}],
          query: ""
        },
        %{},
        []
      )

    assert [%Dlex.Api.Mutation{set: [%Dlex.Api.NQuad{} = encoded]}] = request.mutations
    assert encoded.subject == "0x1"
    assert encoded.predicate == "friend"
    assert encoded.object_id == "0x2"
    assert [%Dlex.Api.Facet{key: "close", val_type: :BOOL, value: "true"}] = encoded.facets
  end

  test "constructs every structured Dgraph value kind" do
    constructors = [
      Dlex.NQuad.default_value("0x1", "default", "value"),
      Dlex.NQuad.bytes("0x1", "bytes", <<1, 2>>),
      Dlex.NQuad.date("0x1", "date", <<1>>),
      Dlex.NQuad.datetime("0x1", "datetime", <<2>>),
      Dlex.NQuad.geo("0x1", "geo", <<3>>),
      Dlex.NQuad.password("0x1", "password", "secret"),
      Dlex.NQuad.bigfloat("0x1", "bigfloat", <<4>>),
      Dlex.NQuad.vector("0x1", "embedding", <<5>>)
    ]

    assert Enum.map(constructors, & &1.object_value.val) == [
             {:default_val, "value"},
             {:bytes_val, <<1, 2>>},
             {:date_val, <<1>>},
             {:datetime_val, <<2>>},
             {:geo_val, <<3>>},
             {:password_val, "secret"},
             {:bigfloat_val, <<4>>},
             {:vfloat32_val, <<5>>}
           ]
  end

  test "builds non-executing wildcard DeleteEdges NQuads" do
    assert [
             %Dlex.Api.NQuad{subject: "0x1", predicate: "friend"} = friend,
             %Dlex.Api.NQuad{subject: "0x1", predicate: "name"} = name
           ] = Dlex.NQuad.delete_edges("0x1", ["friend", "name"])

    assert friend.object_value.val == {:default_val, "_STAR_ALL"}
    assert name.object_value.val == {:default_val, "_STAR_ALL"}
  end
end
