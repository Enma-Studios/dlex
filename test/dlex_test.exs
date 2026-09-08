defmodule DlexTest do
  use ExUnit.Case

  alias Dlex.TestHelper

  setup_all do
    # Setup our server
    {:ok, pid} = Dlex.start_link([{:pool_size, 2} | TestHelper.opts()])
    Dlex.alter!(pid, %{drop_all: true})

    schema = """
      type User {
        name
        email
        indexed_id
        location
        structured_friend: [uid]
      }

      type Client {
        name
        email
        balance
      }

      type CastMember {
        name
        surname
      }

      type Film {
        name
        release_date
        starring: [CastMember]
      }

      release_date: string .
      starring: [uid] .
      email: string @index(term, hash) .
      name: string @index(term) .
      surname: string @index(term) .
      balance: float .
      indexed_id: int @index(int) .
      location: geo @index(geo) .
      structured_friend: [uid] .
    """

    Dlex.alter!(pid, schema)
    Dlex.set!(pid, %{"name" => "seeded_read_only", "dgraph.type" => "User"})
    %{pid: pid}
  end

  @mutation_json %{
    "name" => "Alice",
    "friends" => [%{"name" => "Betty"}, %{"name" => "Mark"}]
  }

  @mutation_nquads """
  _:luke <name> "Luke Skywalker" .
  _:luke <dgraph.type> "CastMember" .
  _:leia <name> "Princess Leia" .
  _:leia <dgraph.type> "CastMember" .

  _:sw1 <name> "Star Wars: Episode IV - A New Hope" .
  _:sw1 <release_date> "1977-05-25" .
  _:sw1 <starring> _:luke .
  _:sw1 <starring> _:leia .
  _:sw1 <dgraph.type> "Film" .
  """

  test "mutation json", %{pid: pid} do
    assert {:ok, %{uids: uids}} = Dlex.set(pid, @mutation_json)
    assert 3 == map_size(uids)

    assert %{
             json: %{
               "name" => "Alice",
               "uid" => _uid1,
               "friends" => [
                 %{"name" => "Betty", "uid" => _uid2},
                 %{"name" => "Mark", "uid" => _uid3}
               ]
             }
           } = Dlex.set!(pid, @mutation_json, return_json: true)
  end

  @tag :grpc
  test "v25 run dql and response metadata", %{pid: pid} do
    %{uids: %{"v25_feature" => uid}} =
      Dlex.set!(pid, ~s|_:v25_feature <name> "v25 feature" .|)

    assert %{"feature" => [%{"uid" => ^uid}]} =
             Dlex.run_dql!(pid, "{ feature(func: uid(#{uid})) { uid } }")

    assert {:ok, %{result: %{"feature" => _}, metadata: %{latency: _, metrics: _}}} =
             Dlex.run_dql(pid, "{ feature(func: uid(#{uid})) { uid } }", %{},
               return_metadata: true
             )

    assert is_binary(
             Dlex.run_dql!(pid, "{ feature(func: uid(#{uid})) { uid } }", %{}, resp_format: :rdf)
           )
  end

  @tag :grpc
  test "v25 id allocation and namespace management", %{pid: pid} do
    assert %{start: start_id, end: end_id} = Dlex.allocate_ids!(pid, 2)
    assert end_id - start_id == 1

    assert %{namespace: namespace} = Dlex.create_namespace!(pid)
    assert %{namespaces: namespaces} = Dlex.list_namespaces!(pid)
    assert %{^namespace => %{id: ^namespace}} = namespaces
    assert %{} = Dlex.drop_namespace!(pid, namespace)
  end

  @tag :grpc
  test "authentication operations reach Dgraph", %{pid: pid} do
    assert {:error, %Dlex.Error{action: :execute, reason: %GRPC.RPCError{}}} =
             Dlex.login(pid, "dgraph", "invalid-password")

    assert {:error, %Dlex.Error{action: :execute, reason: %GRPC.RPCError{}}} =
             Dlex.login_into_namespace(pid, "dgraph", "invalid-password", 0)

    assert {:error, %Dlex.Error{action: :execute, reason: %GRPC.RPCError{}}} =
             Dlex.relogin(pid, "invalid-refresh-token")
  end

  @tag :grpc
  test "fulltext and HNSW indexes", %{pid: pid} do
    Dlex.alter!(
      pid,
      "search_text: string @index(fulltext) .\nembedding: float32vector @index(hnsw(metric:\"cosine\")) ."
    )

    Dlex.mutate!(pid, %{
      set: [
        %{
          "search_text" => "quick brown fox",
          "embedding" => "[1.0, 0.0]"
        },
        %{
          "search_text" => "slow green turtle",
          "embedding" => "[0.0, 1.0]"
        }
      ]
    })

    assert %{"search" => [%{"search_text" => "quick brown fox"}]} =
             Dlex.query!(
               pid,
               "{search(func: alloftext(search_text, \"quick brown\")) {search_text}}"
             )

    assert %{"similar" => [%{"search_text" => "quick brown fox"}]} =
             Dlex.query!(
               pid,
               "query similar($vec: float32vector) {similar(func: similar_to(embedding, 1, $vec)) {search_text}}",
               %{"$vec" => [1.0, 0.0]}
             )
  end

  @tag :grpc
  test "structured NQuad mutations and facets", %{pid: pid} do
    %{uids: %{"structured_source" => source, "structured_target" => target}} =
      Dlex.mutate!(pid, %{
        set: [
          %{"uid" => "_:structured_source", "name" => "Structured source"},
          %{"uid" => "_:structured_target", "name" => "Structured target"}
        ]
      })

    relationship =
      Dlex.NQuad.uid(source, "structured_friend", target,
        facets: [Dlex.NQuad.boolean_facet("close", true)]
      )

    assert %{uids: %{}} = Dlex.mutate!(pid, %{set: [relationship]})

    assert %{
             "source" => [%{"structured_friend" => [%{"name" => "Structured target"}]}]
           } =
             Dlex.query!(
               pid,
               "{source(func: uid(#{source})) {structured_friend @facets {name}}}"
             )
  end

  @tag :http
  test "HTTP rejects RDF response format", %{pid: pid} do
    assert {:error, %Dlex.Error{reason: %Dlex.Adapters.HTTP.Error{message: message}}} =
             Dlex.query(pid, "{ health(func: has(name)) { uid } }", %{}, resp_format: :rdf)

    assert message == "RDF responses require the gRPC transport"
  end

  @tag :http
  test "HTTP rejects structured NQuad mutations", %{pid: pid} do
    nquad = Dlex.NQuad.string("_:http_structured", "name", "HTTP structured")

    assert {:error, %Dlex.Error{reason: %Dlex.Adapters.HTTP.Error{message: message}}} =
             Dlex.mutate(pid, %{set: [nquad]})

    assert message == "Structured NQuad mutations require the gRPC transport"
  end

  @tag :http
  test "HTTP returns query metadata", %{pid: pid} do
    assert {:ok, %{result: %{"metadata_query" => _}, metadata: %{latency: latency}}} =
             Dlex.query(pid, "{metadata_query(func: has(name)) {uid}}", %{},
               return_metadata: true
             )

    assert is_map(latency)
  end

  test "mutation nquads", %{pid: pid} do
    assert %{uids: %{"luke" => uid_luke, "leia" => _uid_leia, "sw1" => _uid_sw1}} =
             Dlex.set!(pid, @mutation_nquads)

    assert %{"name" => "Luke Skywalker"} == uid_get(pid, uid_luke)
  end

  test "query with parameters", %{pid: pid} do
    json = %{"name" => "Foo", "surname" => "bar", "dgraph.type" => "CastMember"}
    assert %{json: %{"uid" => uid}} = Dlex.set!(pid, json, return_json: true)
    assert %{"uid" => ^uid, "name" => "Foo", "surname" => "bar"} = get_by_name(pid, "Foo")
  end

  test "query qith different type of parameters", %{pid: pid} do
    json = %{
      "name" => "UserFoo",
      "email" => "userfoo@foobar",
      "indexed_id" => 99,
      "location" => %{
        "type" => "Point",
        "coordinates" => [-122.5, 37.8]
      },
      "dgraph.type" => "User"
    }

    assert %{json: %{"uid" => _uid}} = Dlex.set!(pid, json, return_json: true)

    statement = "query all($id: int) {all(func: eq(indexed_id, $id)) {uid expand(_all_)}}"

    assert %{"all" => [%{"name" => "UserFoo"}]} = Dlex.query!(pid, statement, %{"$id" => 99})
  end

  test "basic transaction test", %{pid: pid} do
    Dlex.set!(pid, %{"dgraph.type" => "Client", "name" => "client1", "balance" => 1000})
    Dlex.set!(pid, %{"dgraph.type" => "Client", "name" => "client2", "balance" => 1000})

    tasks = for i <- [1, 2], do: Task.async(fn -> move_balance(pid, i * 100) end)
    results = for task <- tasks, do: Task.await(task)

    assert [
             {:ok, _},
             {:error,
              %Dlex.Error{
                action: :commit,
                reason: %{message: "Transaction has been aborted. Please retry"}
              }}
           ] = results

    %{"balance" => balance1} = get_by_name(pid, "client1")
    %{"balance" => balance2} = get_by_name(pid, "client2")
    assert balance1 + balance2 == 2000
  end

  test "read-only and best-effort transactions", %{pid: pid} do
    assert {:ok, %{"seeded" => [%{"name" => "seeded_read_only"}]}} =
             Dlex.read_only_transaction(pid, fn conn ->
               Dlex.query!(conn, "{seeded(func: eq(name, \"seeded_read_only\")) {name}}")
             end)

    assert {:ok, %{"seeded" => [%{"name" => "seeded_read_only"}]}} =
             Dlex.best_effort_transaction(pid, fn conn ->
               Dlex.query!(conn, "{seeded(func: eq(name, \"seeded_read_only\")) {name}}")
             end)

    assert {:error, %Dlex.Error{action: :execute, reason: :read_only_transaction}} =
             Dlex.read_only_transaction(pid, fn conn ->
               Dlex.set!(conn, %{"name" => "read_only_mutation"})
             end)
  end

  test "deletion", %{pid: pid} do
    assert %{json: %{"uid" => uid}} =
             Dlex.set!(pid, %{"name" => "deletion_test", "dgraph.type" => "CastMember"},
               return_json: true
             )

    assert %{"uid" => ^uid} = get_by_name(pid, "deletion_test")
    assert Dlex.delete!(pid, %{"uid" => uid}, return_json: true)
    assert %{"all" => []} = get_by_name(pid, "deletion_test")
  end

  test "schema modification with map", %{pid: pid} do
    surname_predicate = %{
      "index" => true,
      "predicate" => "surname",
      "tokenizer" => ["term", "fulltext"],
      "type" => "string"
    }

    Dlex.alter!(pid, [surname_predicate])
    {:ok, %{"schema" => schema}} = Dlex.query_schema(pid)
    assert surname_predicate == Enum.find(schema, &(&1["predicate"] == "surname"))
  end

  test "alter drop operation controls", %{pid: pid} do
    predicate = "drop_surface_test"
    Dlex.alter!(pid, "#{predicate}: string .")

    assert {:ok, %{"schema" => schema}} = Dlex.query_schema(pid)
    assert Enum.any?(schema, &(&1["predicate"] == predicate))

    Dlex.alter!(pid, %{drop_op: :attr, drop_value: predicate})

    assert {:ok, %{"schema" => schema}} = Dlex.query_schema(pid)
    refute Enum.any?(schema, &(&1["predicate"] == predicate))
  end

  test "malformed query", %{pid: pid} do
    assert {:error, error} = Dlex.query(pid, "{ fail(func: eq(name, [])) { uid } } ")
    assert String.contains?(error.reason.message, "Empty Argument")
  end

  describe "upsert" do
    setup [:upsert_schema]

    test "basic", %{pid: pid} do
      # insert new node
      %{uids: uids} =
        Dlex.mutate!(pid, %{
          set: %{
            "name" => "upsert_test",
            "email" => "foo@bar",
            "dgraph.type" => "Client"
          }
        })

      # grab the uid to test the rest of the mutations with
      assert [new_uid] = Map.values(uids)
      assert new_uid && new_uid !== ""

      # assert existing node uid used, :json key is missing when return_json: false used
      %{uids: uids, queries: %{"q" => [%{"uid" => ^new_uid}]}} =
        resp1 =
        Dlex.mutate!(
          pid,
          %{query: ~s|{ q(func: eq(email, "foo@bar")) { v as uid } }|},
          %{set: ~s|uid(v) <email> "foo@bar_changed" .|},
          return_json: false
        )

      assert uids === %{}
      # assert existing node uid used, :json === %{} when return_json: true and nquad mutation
      refute Map.has_key?(resp1, :json)

      assert %{"email" => "foo@bar_changed"} = get_by_name(pid, "upsert_test")

      query = %{query: ~s|{ q(func: eq(email, "foo@bar_changed")) { v as uid } }|}

      assert %{json: json, uids: uids, queries: %{"q" => [%{"uid" => ^new_uid}]}} =
               Dlex.set!(pid, query, ~s|uid(v) <email> "foo@bar_changed2" .|, return_json: true)

      assert json === %{}
      assert uids === %{}

      assert %{"email" => "foo@bar_changed2"} = get_by_name(pid, "upsert_test")

      # assert existing node used when email already exists, :json has data in it, :query is empty when `var` used
      query = %{query: ~s|{ v as var(func: eq(email, "foo@bar_changed2")) }|}
      mutation_json = %{"uid" => "uid(v)", "email" => "foo@bar_changed3"}

      assert %{
               json: %{"uid" => "uid(v)", "email" => "foo@bar_changed3"},
               uids: uids,
               queries: queries
             } = Dlex.mutate!(pid, query, %{set: mutation_json}, return_json: true)

      assert uids === %{}
      assert queries === %{}

      assert %{"email" => "foo@bar_changed3"} = get_by_name(pid, "upsert_test")
    end

    test "conditions", %{pid: pid} do
      Dlex.mutate!(pid, %{
        set: %{
          "name" => "upsert_test_2",
          "email" => "foo@baz",
          "dgraph.type" => "Client"
        }
      })

      query = %{
        query: ~s|{ v as var(func: eq(email, "foo@baz")) }|
      }

      mutation_json = %{"uid" => "uid(v)", "email" => "foo@baz_changed"}

      mutation = %{cond: ~s|@if(eq(len(v), 2))|, set: mutation_json}
      Dlex.mutate!(pid, query, mutation, return_json: true)

      assert %{"email" => "foo@baz"} = get_by_name(pid, "upsert_test_2")

      mutation = %{cond: ~s|@if(eq(len(v), 1))|, set: mutation_json}
      Dlex.mutate!(pid, query, mutation, return_json: true)

      assert %{"email" => "foo@baz_changed"} = get_by_name(pid, "upsert_test_2")
    end

    @tag :grpc
    test "with variables in query in mutation", %{pid: pid} do
      Dlex.mutate!(pid, %{
        set: %{
          "name" => "upsert_test_3",
          "email" => "foobar@upsert_test_3",
          "dgraph.type" => "Client"
        }
      })

      query = %{
        query: ~s|query var($email: string) { v as var(func: eq(email, $email)) }|,
        vars: %{"$email" => "foobar@upsert_test_3"}
      }

      mutation_json = %{"uid" => "uid(v)", "email" => "foobaz@upsert_test_3"}

      mutation = %{cond: ~s|@if(eq(len(v), 2))|, set: mutation_json}
      Dlex.mutate!(pid, query, mutation, return_json: true)

      assert %{"email" => "foobar@upsert_test_3"} = get_by_name(pid, "upsert_test_3")

      mutation = %{cond: ~s|@if(eq(len(v), 1))|, set: mutation_json}
      Dlex.mutate!(pid, query, mutation, return_json: true)

      assert %{"email" => "foobaz@upsert_test_3"} = get_by_name(pid, "upsert_test_3")
    end

    test "set and delete", %{pid: pid} do
      Dlex.mutate!(pid, %{set: test_data("@set_delete")})

      query = %{query: ~s|{ v as var(func: regexp(email, /.*@set_delete$/)) { a as age } }|}

      Dlex.mutate!(pid, query, %{
        delete: %{"uid" => "uid(v)", "age" => nil},
        set: %{"uid" => "uid(v)", "new_age" => "val(a)"}
      })

      check_migrated(pid, "@set_delete")
    end

    test "multiple mutations", %{pid: pid} do
      Dlex.mutate!(pid, %{set: test_data("@multiple_migrations")})

      query = %{
        query: ~s|{ v as var(func: regexp(email, /.*@multiple_migrations$/)) { a as age } }|
      }

      Dlex.mutate!(pid, query, [
        %{delete: %{"uid" => "uid(v)", "age" => nil}},
        %{set: %{"uid" => "uid(v)", "new_age" => "val(a)"}}
      ])

      check_migrated(pid, "@multiple_migrations")
    end

    test "multiple mutations with nquads", %{pid: pid} do
      Dlex.mutate!(pid, %{set: test_data("@multiple_migrations_nquads")})

      query = %{
        query:
          ~s|{ v as var(func: regexp(email, /.*@multiple_migrations_nquads$/)) { a as age } }|
      }

      Dlex.mutate!(pid, query, [
        %{delete: "uid(v) <age> * ."},
        %{set: "uid(v) <new_age> val(a) ."}
      ])

      check_migrated(pid, "@multiple_migrations_nquads")
    end

    defp test_data(prefix) do
      [
        %{"age" => 20, "email" => "foo#{prefix}", "dgraph.type" => "Client"},
        %{"age" => 25, "email" => "bar#{prefix}", "dgraph.type" => "Client"}
      ]
    end

    defp check_migrated(pid, prefix) do
      query = "{all(func: regexp(email, /.*#{prefix}$/)) @filter(has(age)) {uid age}}"
      assert %{"all" => []} = Dlex.query!(pid, query)

      query = "{all(func: regexp(email, /.*#{prefix}$/)) @filter(has(new_age)) {uid new_age}}"

      assert %{"all" => [_, _]} = Dlex.query!(pid, query)
    end
  end

  defp upsert_schema(%{pid: pid} = context) do
    predicate = %{
      "upsert" => true,
      "index" => true,
      "predicate" => "email",
      "tokenizer" => ["exact", "trigram"],
      "type" => "string"
    }

    Dlex.alter!(pid, [predicate])
    context
  end

  def uid_get(conn, uid) do
    statement = "{uid_get(func: uid(#{uid})) {expand(_all_)}}"
    with %{"uid_get" => [obj]} <- Dlex.query!(conn, statement), do: obj
  end

  defp get_by_name(conn, name) do
    statement = "query all($a: string) {all(func: eq(name, $a)) {uid expand(_all_)}}"
    with %{"all" => [obj]} <- Dlex.query!(conn, statement, %{"$a" => name}), do: obj
  end

  defp move_balance(pid, sum) do
    Dlex.transaction(pid, fn conn ->
      %{"uid" => uid1, "balance" => balance1} = get_by_name(conn, "client1")
      %{"uid" => uid2, "balance" => balance2} = get_by_name(conn, "client2")

      if sum == 100, do: :timer.sleep(50)
      Dlex.set!(conn, %{"uid" => uid1, "balance" => balance1 - sum}, return_json: true)

      if sum == 200, do: :timer.sleep(100)
      Dlex.set!(conn, %{"uid" => uid2, "balance" => balance2 + sum}, return_json: true)
    end)
  end
end
