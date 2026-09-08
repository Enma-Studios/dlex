# Dlex

[![Hex pm](http://img.shields.io/hexpm/v/dlex.svg?style=flat)](https://hex.pm/packages/dlex)
[![CircleCI](https://circleci.com/gh/Enma-Studios/dlex.svg?style=svg)](https://circleci.com/gh/Enma-Studios/dlex)

Dlex is a gRPC based client for the [Dgraph](https://github.com/dgraph-io/dgraph) database in Elixir.
It uses the [DBConnection](https://hexdocs.pm/db_connection/DBConnection.html) behaviour to support transactions and connection pooling.

This repository is an actively maintained port of the original Dlex project for the Enma Studios
organization. The source is hosted at [Enma-Studios/dlex](https://github.com/Enma-Studios/dlex).
API documentation is published automatically to [GitHub Pages](https://enma-studios.github.io/dlex/)
by GitHub Actions.

Small, efficient codebase. Aims for full Dgraph support. Supports transactions, delete mutations and low-level parameterized queries. The integration suite targets Dgraph `v25.4.0`.

Supports the Dgraph [Type System](https://docs.dgraph.io/master/query-language/#type-system).

## Installation

This port is installed directly from GitHub by adding `dlex` to your list of dependencies in
`mix.exs`:

Preferred and more performant option is to use `grpc`:

```elixir
def deps do
  [
    {:jason, "~> 1.0"},
    {:dlex, github: "Enma-Studios/dlex"}
  ]
end
```

`http` transport:

```elixir
def deps do
  [
    {:jason, "~> 1.0"},
    {:castore, "~> 0.1.0", optional: true},
    {:mint, "~> 1.9"},
    {:dlex, github: "Enma-Studios/dlex"}
  ]
end
```

## Usage examples

```elixir
# try to connect to `localhost:9080` by default
{:ok, conn} = Dlex.start_link(name: :example)

# clear any data in the graph
Dlex.alter!(conn, %{drop_all: true})

# add a term index on then `name` predicate
{:ok, _} = Dlex.alter(conn, "name: string @index(term) .")

# add nodes, returning the uids in the response
mut = %{
  "name" => "Alice",
  "friends" => [%{"name" => "Betty"}, %{"name" => "Mark"}]
}
{:ok, %{json: %{"uid" => uid}}} = Dlex.mutate(conn, mut, return_json: true)

# use the nquad format for mutations instead if preferred
Dlex.mutate(conn, ~s|_:foo <name> "Bar" .|)

# basic query that shows Betty
by_name = "query by_name($name: string) {by_name(func: eq(name, $name)) {uid expand(_all_)}}"
Dlex.query(conn, by_name, %{"$name" => "Betty"})

# delete the Alice node
Dlex.delete(conn, %{"uid" => uid})
```

Structured NQuad mutations and facets are available through gRPC:

```elixir
edge = Dlex.NQuad.uid(source_uid, "friend", target_uid,
  facets: [Dlex.NQuad.boolean_facet("close", true)]
)

Dlex.mutate!(conn, %{set: [edge]})
Dlex.delete_edges!(conn, source_uid, "friend")
```

Abort a transaction from inside its callback with `Dlex.discard(conn, reason)` (or
`Dlex.rollback/2`).

### Dgraph v25 APIs

The v25 gRPC API is available through the following helpers. Each helper has a bang variant
(`run_dql!`, `allocate_ids!`, `create_namespace!`, `drop_namespace!`, and
`list_namespaces!`) that returns the result directly and raises on failure:

```elixir
# Execute DQL as JSON (the default)
Dlex.run_dql(conn, "{ users(func: has(name)) { uid name } }")

# Request RDF and response metadata
Dlex.run_dql(conn, "{ users(func: has(name)) { uid name } }", %{},
  resp_format: :rdf,
  return_metadata: true
)
# => {:ok, %{result: "...", metadata: %{latency: ..., metrics: ...}}}

# Allocate IDs and manage namespaces
Dlex.allocate_ids!(conn, 100, :uid)
namespace = Dlex.create_namespace!(conn).namespace
Dlex.list_namespaces!(conn)
Dlex.drop_namespace!(conn, namespace)

# Check the server version
Dlex.check_version!(conn)

# Control external snapshot streaming (gRPC)
Dlex.update_ext_snapshot_streaming_state!(conn, start: false, finish: false)
```

### Authentication

The gRPC transport exposes Dgraph login and refresh-token operations:

```elixir
tokens = Dlex.login!(conn, "alice", "password")
tokens = Dlex.login_into_namespace!(conn, "alice", "password", 1)
tokens = Dlex.relogin!(conn, tokens.refresh_jwt)
```

Login and relogin remember the access token for subsequent requests through the same pool. To
start a pool with a token that was obtained elsewhere, pass it as a connection header:

```elixir
Dlex.start_link(headers: [{"accessJwt", tokens.access_jwt}])
```

These administrative operations require the gRPC transport. The HTTP transport continues to support queries, mutations, schema alterations, and transaction commits.

The `:resp_format` option accepts `:json` or `:rdf`; `:return_metadata` adds latency and UID
metrics to the result. Both options are available on `query/4`, `mutate/4`, and `run_dql/4`, but
RDF responses require gRPC. HTTP requests using `resp_format: :rdf` return an error.

For example, the same response options can be used with a query or mutation:

```elixir
Dlex.query(conn, "{ users(func: has(name)) { uid name } }", %{},
  resp_format: :rdf,
  return_metadata: true
)

Dlex.mutate(conn, %{"name" => "Alice"},
  resp_format: :rdf,
  return_metadata: true
)
```

### Alter schema

Modification of schema supported with string and map form (which is returned by `query_schema`):

```elixir
Dlex.alter(conn, "name: string @index(term, fulltext, trigram) @lang .")

# equivalent map form
Dlex.alter(conn, [
  %{
    "predicate" => "name",
    "type" => "string",
    "index" => true,
    "lang" => true,
    "tokenizer" => ["term", "fulltext", "trigram"]
  }
])
```

Full-text search uses the `fulltext` tokenizer with DQL functions such as `alloftext/2` and
`anyoftext/2`. HNSW vector search is available through the `float32vector` type and
`similar_to/3`:

```elixir
Dlex.alter(conn, "body: string @index(fulltext) .\nembedding: float32vector @index(hnsw(metric:\"cosine\")) .")

Dlex.mutate!(conn, %{
  set: %{"body" => "quick brown fox", "embedding" => "[1.0, 0.0]"}
})

Dlex.query!(conn, "{docs(func: alloftext(body, \"quick brown\")) {uid body}}")

Dlex.query!(conn,
  "query similar($vector: float32vector) {docs(func: similar_to(embedding, 1, $vector)) {uid body}}",
  %{"$vector" => [1.0, 0.0]}
)
```

The `Dlex.Node` schema DSL supports the same features. Use `:float32vector` for vector fields;
`index: true` creates a default HNSW index, while a tokenizer string can specify HNSW options:
typed `Dlex.Repo` mutations accept the vector as a float list and encode the backend literal.

```elixir
field :body, :string, index: ["fulltext"]
field :embedding, :float32vector, index: ["hnsw(metric:\"cosine\", exponent:\"4\")"]
```

## Developers guide

### Running tests

1. Install dependencies `mix deps.get`
2. Start the local dgraph server (requires Docker) `./start-server.sh`
   This starts a local server bound to ports 9090 (GRPC) and 8090 (HTTP)
3. Run `DLEX_PORT_OFFSET=10 mix test`

   Run the HTTP transport suite with `DLEX_PORT_OFFSET=10 mix test.http`.

NOTE: You may stop the server using `./stop-server.sh`

### Updating GRPC stubs based on api.proto

#### Install development dependencies

1. Install `protoc`(cpp) [here](https://github.com/google/protobuf/blob/master/src/README.md) or `brew install protobuf` on MacOS.
2. Install protoc plugin `protoc-gen-elixir` for Elixir . NOTE: You have to make sure `protoc-gen-elixir`(this name is important) is in your PATH.

```bash
mix escript.install hex protobuf
```

#### Generate Elixir code based on api.proto

3. Generate Elixir code using protoc

```bash
protoc --elixir_out=plugins=grpc:. lib/api.proto
```

4. Files `lib/api.pb.ex` will be generated

5. Rename `lib/api.pb.ex` to `lib/dlex/api.ex` and add `alias Dlex.Api` to be compliant with Elixir naming

## Credits

Inspired by [exdgraph](https://github.com/ospaarmann/exdgraph), but as I saw too many parts for changes or parts, which I would like to have completely different, so that it was easier to start from scratch with these goals: small codebase, small natural abstraction, efficient, less opinionated, less dependencies.

So you can choose freely which pool implementation to use (poolboy or db_connection intern pool implementation) or which JSON adapter to use. Fewer dependencies.

It seems for me more natural to have API names more or less matching actual query names.

For example `Dlex.mutate()` instead of `ExDgraph.set_map` for JSON-based mutations. Actually, `Dlex.mutate` infers the type (JSON or nquads) from data passed to a function.

## License

   Copyright 2018 Dmitry Russ

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
