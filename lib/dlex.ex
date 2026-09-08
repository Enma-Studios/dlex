defmodule Dlex do
  @moduledoc """
  Dgraph driver for Elixir.

  This module handles the connection to Dgraph, providing pooling (via `DBConnection`), queries,
  mutations and transactions.
  """

  alias Dlex.{Error, Query, Type}
  alias Dlex.Api
  alias Dlex.Utils

  @type conn :: DBConnection.conn()
  @type uid :: String.t()
  @type query :: iodata
  @type query_map :: %{:query => query, optional(:vars) => map}
  @type statement :: iodata | map
  @type mutation :: %{
          optional(:cond) => iodata,
          optional(:set) => statement(),
          optional(:delete) => statement()
        }
  @type mutations :: [mutation]
  @type response_format :: :json | :rdf
  @type lease_type :: :uid | :timestamp | :namespace

  @timeout 15_000
  @default_keepalive :infinity
  @idle_interval 15_000

  @doc """
  Start dgraph connection process.

  ## Options

    * `:hostname` - Server hostname (default: DGRAPH_HOST, than `localhost`)
    * `:port` - Server port (default: DGRAPH_PORT env var, then 9080)
    * `:keepalive` - Keepalive option for http client (default: `:infinity`)
    * `:json_library` - Specifies json library to use (default: `Jason`)
    * `:transport` - Specify if grpc or http should be used (default: `grpc`)
    * `:connect_timeout` - Connection timeout in milliseconds (default: `#{@timeout}`);

  ### SSL/TLS configuration (automaticly enabled, if required files provided)

    * `:cacertfile` - Path to your CA certificate. Should be provided for SSL authentication
    * `:certfile` - Path to client certificate. Should be additionally provided for TSL
      authentication
    * `:keyfile` - Path to client key. Should be additionally provided for TSL authentication

  ### DBConnection options

    * `:backoff_min` - The minimum backoff interval (default: `1_000`)
    * `:backoff_max` - The maximum backoff interval (default: `30_000`)
    * `:backoff_type` - The backoff strategy, `:stop` for no backoff and
    to stop, `:exp` for exponential, `:rand` for random and `:rand_exp` for
    random exponential (default: `:rand_exp`)
    * `:name` - A name to register the started process (see the `:name` option
    in `GenServer.start_link/3`)
    * `:pool` - Chooses the pool to be started
    * `:pool_size` - Chooses the size of the pool
    * `:queue_target` in microseconds, defaults to 50
    * `:queue_interval` in microseconds, defaults to 1000

  ## Example of usage

      iex> {:ok, conn} = Dlex.start_link()
      {:ok, #PID<0.216.0>}
  """
  @spec start_link(Keyword.t()) :: {:ok, pid} | {:error, Dlex.Error.t() | term}
  def start_link(opts \\ []) do
    opts = default_opts(opts)
    DBConnection.start_link(Dlex.Protocol, opts)
  end

  defp default_opts(opts) do
    opts
    |> Keyword.put_new(:hostname, System.get_env("DGRAPH_HOST") || "localhost")
    |> Keyword.put_new(:port, System.get_env("DGRAPH_PORT") || 9080)
    |> Keyword.put_new(:transport, :grpc)
    |> Keyword.put_new(:connect_timeout, @timeout)
    |> Keyword.put_new(:timeout, @timeout)
    |> Keyword.put_new(:keepalive, @default_keepalive)
    |> Keyword.put_new(:idle_interval, @idle_interval)
    |> Keyword.update!(:port, &to_integer/1)
    |> Keyword.put_new_lazy(:json_library, fn -> json_library() end)
  end

  defp json_library(), do: Application.get_env(:dlex, :json_library, Jason)

  defp to_integer(port) when is_binary(port), do: String.to_integer(port)
  defp to_integer(port) when is_integer(port), do: port

  @doc """
  Supervisor callback.

  For available options, see: `start_link/1`.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.Spec.spec()
  def child_spec(opts) do
    opts = default_opts(opts)
    DBConnection.child_spec(Dlex.Protocol, opts)
  end

  @doc """
  Alter dgraph schema

  Example

      iex> Dlex.alter(conn, "name: string @index(term) .")
      {:ok, ""}

  ## Options

    * `:timeout` - Call timeout (default: `#{@timeout}`)
  """
  @spec alter(conn, iodata | map, Keyword.t()) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def alter(conn, statement, opts \\ []) do
    query = %Query{type: Type.Operation, statement: statement}

    with {:ok, _, result} <- prepare_execute(conn, query, %{}, opts),
         do: {:ok, result}
  end

  @doc """
  Alter dgraph schema
  """
  @spec alter(conn, iodata | map, Keyword.t()) :: map
  def alter!(conn, statement, opts \\ []) do
    case alter(conn, statement, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Send mutation to dgraph. Shortcut for `mutate(conn, query, %{set: statement}, opts)`

  Options:

    * `return_json` - if json with uids should be returned (default: `false`)

  Example of usage

      iex> mutation = "
           _:foo <name> "Foo" .
           _:foo <owns> _:bar .
            _:bar <name> "Bar" .
           "
      iex> Dlex.set(conn, mutation)
      {:ok, %{uids: %{"bar" => "0xfe04c", "foo" => "0xfe04b"}, queries: %{}}}

  Using `json`

      iex> json = %{"name" => "Foo", "owns" => [%{"name" => "Bar"}]}
           Dlex.set(conn, json)
      {:ok, %{uids: %{"blank-0" => "0xfe04d", "blank-1" => "0xfe04e"}, queries: %{}}}
      iex> Dlex.set(conn, json, return_json: true)
      {:ok,
       %{json: %{
         "name" => "Foo",
         "owns" => [%{"name" => "Bar", "uid" => "0xfe050"}],
         "uid" => "0xfe04f"
       }}}

  ## Options

    * `:timeout` - Call timeout (default: `#{@timeout}`)

  """

  @spec set(conn, query_map, statement, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}

  def set(conn, query, statement, opts), do: mutate(conn, query, %{set: statement}, opts)

  @doc """
  The same as `Dlex.set(conn, "", statement, [])`
  """
  @spec set(conn, statement) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def set(conn, statement), do: mutate(conn, %{}, %{set: statement}, [])

  @doc """
  The same as `Dlex.set(conn, "", statement, opts)`.
  """
  @spec set(conn, query_map | statement, statement | Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def set(conn, %{query: _} = query, statement), do: mutate(conn, query, %{set: statement}, [])
  def set(conn, statement, opts), do: mutate(conn, %{}, %{set: statement}, opts)

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `set/4`.
  """
  @spec set!(conn, query_map, statement, Keyword.t()) :: map | no_return
  def set!(conn, query, statement, opts) do
    case mutate(conn, query, %{set: statement}, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `set/3`.
  """
  @spec set!(conn, query_map | statement, statement | Keyword.t()) :: map | no_return
  def set!(conn, statement, opts) do
    case set(conn, statement, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `set/2`.
  """
  @spec mutate!(conn, statement) :: map | no_return
  def set!(conn, statement) do
    case mutate(conn, %{}, %{set: statement}, []) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Send mutation to dgraph

  Options:

    * `return_json` - if json with uids should be returned (default: `false`)

  Example of usage

      iex> mutation = "
           _:foo <name> "Foo" .
           _:foo <owns> _:bar .
            _:bar <name> "Bar" .
           "
      iex> Dlex.mutate(conn, %{set: mutation})
      {:ok, %{uids: %{"bar" => "0xfe04c", "foo" => "0xfe04b"}, queries: %{}}}

  Using `json`

      iex> json = %{"name" => "Foo", "owns" => [%{"name" => "Bar"}]}
           Dlex.mutate(conn, %{set: json})
      {:ok, %{uids: %{"blank-0" => "0xfe04d", "blank-1" => "0xfe04e"}, queries: %{}}}
      iex> Dlex.mutate(conn, %{set: json}, return_json: true)
      {:ok,
       %{json: %{
         "name" => "Foo",
         "owns" => [%{"name" => "Bar", "uid" => "0xfe050"}],
         "uid" => "0xfe04f"
       }}}

  ## Options

    * `:timeout` - Call timeout (default: `#{@timeout}`)
    * `:resp_format` - `:json` or `:rdf` (gRPC transport)
    * `:return_metadata` - include latency and UID metrics (gRPC transport)
  """

  @spec mutate(conn, query_map, mutations, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}

  def mutate(conn, query_map, mutations, opts) do
    query_statement = Map.get(query_map, :query, "")
    query_vars = Map.get(query_map, :vars, %{})
    query = %Query{type: Type.Mutation, statement: List.wrap(mutations), query: query_statement}

    with {:ok, _, result} <- prepare_execute(conn, query, query_vars, opts),
         do: {:ok, result}
  end

  @doc """
  The same as `Dlex.mutate(conn, "", mutations, [])`
  """
  @spec mutate(conn, mutations) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def mutate(conn, mutations), do: mutate(conn, %{}, mutations, [])

  @doc """
  The same as `Dlex.mutate(conn, "", mutations, opts)`.
  """
  @spec mutate(conn, query_map | mutations, mutations | Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def mutate(conn, %{query: _} = query, mutations), do: mutate(conn, query, mutations, [])
  def mutate(conn, mutations, opts), do: mutate(conn, %{}, mutations, opts)

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `mutate/5`.
  """
  @spec mutate!(conn, query, mutations, Keyword.t()) :: map | no_return
  def mutate!(conn, query, mutations, opts) do
    case mutate(conn, query, mutations, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `mutate/4`.
  """
  @spec mutate!(conn, query | mutations, mutations | Keyword.t()) :: map | no_return
  def mutate!(conn, mutations, opts) do
    case mutate(conn, mutations, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation and returns the result or raises `Dlex.Error` if there was an error.
  See `mutate/2`.
  """
  @spec mutate!(conn, mutations) :: map | no_return
  def mutate!(conn, mutations) do
    case mutate(conn, %{}, mutations, []) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Send mutation to dgraph

  Options:

    * `return_json` - if json with uids should be returned (default: `false`)

  Example of usage

      iex> Dlex.delete(conn, %{"uid" => "0xfe04c"})
      {:ok, %{queries: %{}, uids: %{}}}

  Using `json`

      iex> json = %{"uid" => "0xfe04c"}
           Dlex.delete(conn, json)
      {:ok, %{queries: %{}, uids: %{}}}

      iex> Dlex.delete(conn, json, return_json: true)
      {:ok, %{json: %{"uid" => "0xfe04c"}, queries: %{}, uids: %{}}}

  ## Options

    * `:timeout` - Call timeout (default: `#{@timeout}`)

  """
  @spec delete(conn, query, statement, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def delete(conn, query, statement, opts), do: mutate(conn, query, %{delete: statement}, opts)

  @doc """
  The same as `Dlex.delete(conn, "", deletion, [])`
  """
  @spec delete(conn, statement) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def delete(conn, statement), do: mutate(conn, %{}, %{delete: statement}, [])

  @doc """
  The same as `Dlex.delete(conn, query, deletion, [])` or `Dlex.delete(conn, "", deletion, opts)`
  """
  @spec delete(conn, query | statement, statement | Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def delete(conn, %{query: _} = query, statement),
    do: mutate(conn, query, %{delete: statement}, [])

  def delete(conn, statement, opts), do: mutate(conn, %{}, %{delete: statement}, opts)

  @doc """
  Runs a mutation with delete target and returns the result or raises `Dlex.Error` if there was
  an error. See `delete/4`.
  """
  @spec delete!(conn, query, statement, Keyword.t()) :: map | no_return
  def delete!(conn, query, statement, opts) do
    case mutate(conn, query, %{delete: statement}, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation with delete target and returns the result or raises `Dlex.Error` if there was
  an error. See `delete/3`.
  """
  @spec delete(conn, query | statement, statement | Keyword.t()) :: map | no_return
  def delete!(conn, query_or_statement, statement_or_opts) do
    case delete(conn, query_or_statement, statement_or_opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs a mutation with delete target and returns the result or raises `Dlex.Error` if there was
  an error. See `delete/2`.
  """
  @spec delete(conn, statement) :: map | no_return
  def delete!(conn, statement) do
    case mutate(conn, %{}, %{delete: statement}, []) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Delete all values of one or more predicates from a UID.

  This executes the structured NQuad equivalent of Dgraph Go's `Txn.DeleteEdges` helper.
  Use `Dlex.NQuad.delete_edges/2` when only the NQuads are needed.
  """
  @spec delete_edges(conn, uid, [String.t()] | String.t(), Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def delete_edges(conn, uid, predicates \\ ["*"], opts \\ [])

  def delete_edges(conn, uid, predicates, opts) when is_binary(predicates) do
    delete_edges(conn, uid, [predicates], opts)
  end

  def delete_edges(conn, uid, predicates, opts) when is_list(predicates) do
    nquads = Dlex.NQuad.delete_edges(uid, predicates)
    mutate(conn, %{delete: nquads}, opts)
  end

  @doc """
  Delete all values of one or more predicates from a UID and raise on failure.
  """
  @spec delete_edges!(conn, uid, [String.t()] | String.t(), Keyword.t()) :: map | no_return
  def delete_edges!(conn, uid, predicates, opts \\ []) do
    case delete_edges(conn, uid, predicates, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Send query to dgraph

  Example of usage

      iex> query = "
           query foo($a: string) {
              foo(func: eq(name, $a)) {
                uid
                expand(_all_)
              }
            }
           "
      iex> Dlex.query(conn, query, %{"$a" => "Foo"})
      {:ok, %{"foo" => [%{"name" => "Foo", "uid" => "0xfe04d"}]}}

  Query options (see DGraph documentation for more information):

      * `best_effort` - `boolean`
      * `read_only` - `boolean`
      * `resp_format` - `:json` or `:rdf` (gRPC transport)
      * `return_metadata` - include latency and UID metrics (gRPC transport)
  """
  @spec query(conn, iodata, map, Keyword.t()) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def query(conn, statement, parameters \\ %{}, opts \\ []) do
    query = %Query{type: Type.Query, statement: statement}

    with {:ok, _, result} <- prepare_execute(conn, query, parameters, opts),
         do: {:ok, result}
  end

  @doc """
  Runs a query and returns the result or raises `Dlex.Error` if there was an error.
  See `query/3`.
  """
  @spec query!(conn, iodata, map, Keyword.t()) :: map | no_return
  def query!(conn, statement, parameters \\ %{}, opts \\ []) do
    case query(conn, statement, parameters, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Execute DQL through Dgraph's v25 `RunDQL` API.

  This operation is available through the gRPC transport. Use `resp_format: :rdf` to receive
  the RDF response body, or `return_metadata: true` to include latency and UID metrics.

  Options include `:best_effort`, `:read_only`, `:resp_format`, `:return_metadata`, and the
  standard DBConnection `:timeout` option.
  """
  @spec run_dql(conn, iodata, map, Keyword.t()) :: {:ok, term} | {:error, Dlex.Error.t() | term}
  def run_dql(conn, statement, vars \\ %{}, opts \\ []) do
    request = %Api.RunDQLRequest{
      dql_query: IO.iodata_to_binary(statement),
      vars: Utils.encode_vars(vars),
      read_only: Keyword.get(opts, :read_only, false),
      best_effort: Keyword.get(opts, :best_effort, false),
      resp_format: response_format(Keyword.get(opts, :resp_format, :json))
    }

    admin(conn, :run_dql, request, opts)
  end

  @doc """
  Execute `run_dql/4` and raise on failure.
  """
  @spec run_dql!(conn, iodata, map, Keyword.t()) :: term | no_return
  def run_dql!(conn, statement, vars \\ %{}, opts \\ []) do
    case run_dql(conn, statement, vars, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Allocate a range of IDs from Dgraph.

  `lease_type` may be `:uid`, `:timestamp`, or `:namespace`.
  """
  @spec allocate_ids(conn, pos_integer, lease_type, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def allocate_ids(conn, how_many, lease_type \\ :uid, opts \\ []) do
    request = %Api.AllocateIDsRequest{
      how_many: how_many,
      lease_type: lease_type(lease_type)
    }

    admin(conn, :allocate_ids, request, opts)
  end

  @doc """
  Allocate IDs and raise on failure.
  """
  @spec allocate_ids!(conn, pos_integer, lease_type, Keyword.t()) :: map | no_return
  def allocate_ids!(conn, how_many, lease_type \\ :uid, opts \\ []) do
    case allocate_ids(conn, how_many, lease_type, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Create a Dgraph namespace.
  """
  @spec create_namespace(conn, Keyword.t()) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def create_namespace(conn, opts \\ []) do
    admin(conn, :create_namespace, %Api.CreateNamespaceRequest{}, opts)
  end

  @doc """
  Create a Dgraph namespace and raise on failure.
  """
  @spec create_namespace!(conn, Keyword.t()) :: map | no_return
  def create_namespace!(conn, opts \\ []) do
    case create_namespace(conn, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Drop a Dgraph namespace.
  """
  @spec drop_namespace(conn, non_neg_integer, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def drop_namespace(conn, namespace, opts \\ []) do
    admin(conn, :drop_namespace, %Api.DropNamespaceRequest{namespace: namespace}, opts)
  end

  @doc """
  Drop a Dgraph namespace and raise on failure.
  """
  @spec drop_namespace!(conn, non_neg_integer, Keyword.t()) :: map | no_return
  def drop_namespace!(conn, namespace, opts \\ []) do
    case drop_namespace(conn, namespace, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  List Dgraph namespaces.
  """
  @spec list_namespaces(conn, Keyword.t()) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def list_namespaces(conn, opts \\ []) do
    admin(conn, :list_namespaces, %Api.ListNamespacesRequest{}, opts)
  end

  @doc """
  List Dgraph namespaces and raise on failure.
  """
  @spec list_namespaces!(conn, Keyword.t()) :: map | no_return
  def list_namespaces!(conn, opts \\ []) do
    case list_namespaces(conn, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Log in to Dgraph and return its access and refresh JWTs.

  The access JWT can be sent on a connection by including
  `headers: [{"accessJwt", access_jwt}]` in `start_link/1` options.
  """
  @spec login(conn, String.t(), String.t(), Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def login(conn, userid, password, opts \\ []) do
    request = %Api.LoginRequest{
      userid: userid,
      password: password,
      namespace: Keyword.get(opts, :namespace, 0)
    }

    with {:ok, tokens} <- admin(conn, :login, request, opts) do
      store_access_token(conn, tokens)
      {:ok, tokens}
    end
  end

  @doc """
  Log in to Dgraph and raise on failure.
  """
  @spec login!(conn, String.t(), String.t(), Keyword.t()) :: map | no_return
  def login!(conn, userid, password, opts \\ []) do
    case login(conn, userid, password, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Log in to a Dgraph namespace and return its JWTs.
  """
  @spec login_into_namespace(conn, String.t(), String.t(), non_neg_integer(), Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def login_into_namespace(conn, userid, password, namespace, opts \\ []) do
    login(conn, userid, password, Keyword.put(opts, :namespace, namespace))
  end

  @doc """
  Log in to a Dgraph namespace and raise on failure.
  """
  @spec login_into_namespace!(conn, String.t(), String.t(), non_neg_integer(), Keyword.t()) ::
          map | no_return
  def login_into_namespace!(conn, userid, password, namespace, opts \\ []) do
    case login_into_namespace(conn, userid, password, namespace, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Refresh a Dgraph access JWT using a refresh JWT.

  When called with only the connection, the refresh JWT retained by the most recent
  successful login is used, matching Dgraph Go's `Relogin` behavior.
  """
  @spec relogin(conn, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  @spec relogin(conn, String.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  @spec relogin(conn, String.t(), Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def relogin(conn, opts \\ [])

  def relogin(conn, opts) when is_list(opts) do
    case get_jwt(conn) do
      %{refresh_jwt: refresh_token} when refresh_token not in [nil, ""] ->
        relogin(conn, refresh_token, opts)

      _jwt ->
        {:error, %Error{action: :login, reason: "refresh jwt should not be empty"}}
    end
  end

  def relogin(conn, refresh_token) when is_binary(refresh_token),
    do: relogin(conn, refresh_token, [])

  def relogin(conn, refresh_token, opts) do
    request = %Api.LoginRequest{refresh_token: refresh_token}

    with {:ok, tokens} <- admin(conn, :relogin, request, opts) do
      store_access_token(conn, tokens)
      {:ok, tokens}
    end
  end

  @doc """
  Refresh a Dgraph access JWT and raise on failure. With no refresh token argument,
  the token retained by the most recent successful login is used.
  """
  @spec relogin!(conn, Keyword.t()) :: map | no_return
  @spec relogin!(conn, String.t()) :: map | no_return
  @spec relogin!(conn, String.t(), Keyword.t()) :: map | no_return
  def relogin!(conn, opts \\ [])

  def relogin!(conn, opts) when is_list(opts), do: raise_on_error(relogin(conn, opts))

  def relogin!(conn, refresh_token) when is_binary(refresh_token),
    do: raise_on_error(relogin(conn, refresh_token))

  def relogin!(conn, refresh_token, opts), do: raise_on_error(relogin(conn, refresh_token, opts))

  defp raise_on_error({:ok, result}), do: result
  defp raise_on_error({:error, error}), do: raise(error)

  @doc """
  Return the JWT bundle retained for the connection's pool.

  The result contains `:access_jwt` and `:refresh_jwt`, or empty strings when the
  connection has not logged in yet.
  """
  @spec get_jwt(conn) :: %{access_jwt: String.t(), refresh_jwt: String.t()}
  def get_jwt(conn) do
    case :ets.lookup(ensure_auth_table(), auth_key(conn)) do
      [{_, jwt}] -> jwt
      [] -> %{access_jwt: "", refresh_jwt: ""}
    end
  end

  @doc """
  Check the connected Dgraph server version.
  """
  @spec check_version(conn, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def check_version(conn, opts \\ []) do
    admin(conn, :check_version, %Api.Check{}, opts)
  end

  @doc """
  Check the connected Dgraph server version and raise on failure.
  """
  @spec check_version!(conn, Keyword.t()) :: map | no_return
  def check_version!(conn, opts \\ []) do
    case check_version(conn, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Update Dgraph's external snapshot streaming state.

  Options are `:start`, `:finish`, `:drop_data`, and `:timeout`.
  """
  @spec update_ext_snapshot_streaming_state(conn, Keyword.t()) ::
          {:ok, map} | {:error, Dlex.Error.t() | term}
  def update_ext_snapshot_streaming_state(conn, opts \\ []) do
    request = %Api.UpdateExtSnapshotStreamingStateRequest{
      start: Keyword.get(opts, :start, false),
      finish: Keyword.get(opts, :finish, false),
      drop_data: Keyword.get(opts, :drop_data, false)
    }

    admin(conn, :update_ext_snapshot_streaming_state, request, opts)
  end

  @doc """
  Update external snapshot streaming state and raise on failure.
  """
  @spec update_ext_snapshot_streaming_state!(conn, Keyword.t()) :: map | no_return
  def update_ext_snapshot_streaming_state!(conn, opts \\ []) do
    case update_ext_snapshot_streaming_state(conn, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Stream external snapshot packets through Dgraph and collect its responses.

  The request list must contain `%Dlex.Api.StreamExtSnapshotRequest{}` structs. The connection is
  held for the complete send/receive cycle so a pooled connection cannot be reused while the
  stream is active.
  """
  @spec stream_ext_snapshot(conn, [struct], Keyword.t()) ::
          {:ok, [struct]} | {:error, Dlex.Error.t() | term}
  def stream_ext_snapshot(conn, requests, opts \\ []) do
    result =
      DBConnection.run(conn, fn db_conn ->
        query = %Query{
          type: Type.Admin,
          statement: %{operation: :stream_ext_snapshot, request: nil}
        }

        case DBConnection.prepare_execute(db_conn, query, %{}, opts) do
          {:ok, _, stream} ->
            stream =
              Enum.reduce(requests, stream, fn request, stream ->
                GRPC.Stub.send_request(stream, request)
              end)

            stream = GRPC.Stub.end_stream(stream)

            case GRPC.Stub.recv(stream, grpc_stream_opts(opts)) do
              {:ok, response_stream} -> collect_stream_responses(response_stream)
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, responses} -> {:ok, responses}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, %Error{action: :stream_ext_snapshot, reason: reason}}
    end
  end

  @doc """
  Stream external snapshot packets and raise on failure.
  """
  @spec stream_ext_snapshot!(conn, [struct], Keyword.t()) :: [struct] | no_return
  def stream_ext_snapshot!(conn, requests, opts \\ []) do
    case stream_ext_snapshot(conn, requests, opts) do
      {:ok, responses} -> responses
      {:error, error} -> raise error
    end
  end

  defp grpc_stream_opts(opts), do: Keyword.take(opts, [:timeout, :deadline, :return_headers])

  defp collect_stream_responses(response_stream) do
    Enum.reduce_while(response_stream, [], fn
      {:ok, response}, responses -> {:cont, [response | responses]}
      {:trailers, _trailers}, responses -> {:cont, responses}
      {:error, reason}, _responses -> {:halt, {:error, reason}}
    end)
    |> case do
      responses when is_list(responses) -> {:ok, Enum.reverse(responses)}
      error -> error
    end
  end

  defp admin(conn, operation, request, opts) do
    query = %Query{
      type: Type.Admin,
      statement: %{operation: operation, request: request}
    }

    with {:ok, _, result} <- prepare_execute(conn, query, %{}, opts),
         do: {:ok, result}
  end

  defp prepare_execute(conn, query, parameters, opts) do
    opts =
      case access_token(conn) do
        nil -> opts
        token -> Keyword.put_new(opts, :dlex_access_jwt, token)
      end

    DBConnection.prepare_execute(conn, query, parameters, opts)
  end

  @auth_table :dlex_auth_tokens

  defp store_access_token(conn, %{access_jwt: access_jwt} = tokens)
       when access_jwt not in [nil, ""] do
    table = ensure_auth_table()
    :ets.insert(table, {auth_key(conn), Map.take(tokens, [:access_jwt, :refresh_jwt])})
    :ok
  end

  defp store_access_token(_conn, _tokens), do: :ok

  defp access_token(conn) do
    case get_jwt(conn) do
      %{access_jwt: token} when token not in [nil, ""] -> token
      _jwt -> nil
    end
  end

  defp auth_key(%DBConnection{pool_ref: pool_ref}), do: pool_ref
  defp auth_key(conn), do: conn

  defp ensure_auth_table do
    case :ets.whereis(@auth_table) do
      :undefined ->
        try do
          :ets.new(@auth_table, [:named_table, :public, :set, read_concurrency: true])
        catch
          :error, :badarg -> @auth_table
        end

      _table ->
        @auth_table
    end
  end

  defp response_format(:rdf), do: :RDF
  defp response_format(:json), do: :JSON
  defp response_format(:RDF), do: :RDF
  defp response_format(:JSON), do: :JSON

  defp lease_type(:uid), do: :UID
  defp lease_type(:timestamp), do: :TS
  defp lease_type(:namespace), do: :NS
  defp lease_type(type) when type in [:UID, :TS, :NS], do: type

  @doc """
  Query schema of dgraph
  """
  @spec query_schema(conn) :: {:ok, map} | {:error, Dlex.Error.t() | term}
  def query_schema(conn), do: query(conn, "schema {}")

  @doc """
  Query schema of dgraph
  """
  @spec query_schema!(conn) :: map | no_return
  def query_schema!(conn), do: query!(conn, "schema {}")

  @doc """
  Execute serie of queries and mutations in a transactions
  """
  @spec transaction(conn, (DBConnection.t() -> result :: any), Keyword.t()) ::
          {:ok, result :: any} | {:error, any}
  def transaction(conn, fun, opts \\ []) do
    try do
      DBConnection.transaction(conn, fun, opts)
    catch
      :error, %Dlex.Error{} = error ->
        {:error, error}
    end
  end

  @doc """
  Abort the current transaction and return `reason` from `transaction/3`.

  This is the explicit equivalent of Dgraph Go's `Txn.Discard` for a Dlex transaction callback.
  """
  @spec discard(DBConnection.t(), term()) :: no_return
  def discard(conn, reason \\ :discard), do: DBConnection.rollback(conn, reason)

  @doc """
  Alias for `discard/2`.
  """
  @spec rollback(DBConnection.t(), term()) :: no_return
  def rollback(conn, reason \\ :rollback), do: discard(conn, reason)

  @doc """
  Run a transaction that can only issue read operations.

  The transaction is never committed remotely, matching Dgraph's read-only transaction
  behavior. `:best_effort` may be enabled with the options passed to this function.
  """
  @spec read_only_transaction(conn, (DBConnection.t() -> result :: any), Keyword.t()) ::
          {:ok, result :: any} | {:error, any}
  def read_only_transaction(conn, fun, opts \\ []) do
    transaction(conn, fun, Keyword.put(opts, :read_only, true))
  end

  @doc """
  Run a best-effort read-only transaction.
  """
  @spec best_effort_transaction(conn, (DBConnection.t() -> result :: any), Keyword.t()) ::
          {:ok, result :: any} | {:error, any}
  def best_effort_transaction(conn, fun, opts \\ []) do
    transaction(conn, fun, Keyword.merge(opts, read_only: true, best_effort: true))
  end
end
