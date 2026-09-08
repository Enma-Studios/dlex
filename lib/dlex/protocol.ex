defmodule Dlex.Protocol do
  @moduledoc false

  alias Dlex.{Adapter, Error, Type, Query}
  alias Dlex.Api.TxnContext

  use DBConnection

  require Logger

  defstruct [
    :adapter,
    :channel,
    :connected,
    :json,
    :opts,
    :txn_context,
    txn_aborted?: false,
    txn_mutated?: false,
    txn_read_only?: false,
    txn_best_effort?: false
  ]

  @timeout 15_000

  @impl true
  def connect(opts) do
    host = Keyword.fetch!(opts, :hostname)
    port = Keyword.fetch!(opts, :port)
    adapter = opts |> Keyword.fetch!(:transport) |> get_adapter()
    json_lib = Keyword.fetch!(opts, :json_library)

    case Adapter.connect(adapter, host, port, opts) do
      {:ok, channel} ->
        state = %__MODULE__{adapter: adapter, json: json_lib, channel: channel, opts: opts}
        {:ok, state}

      {:error, reason} ->
        {:error, %Error{action: :connect, reason: reason}}
    end
  end

  defp get_adapter(:grpc), do: Dlex.Adapters.GRPC
  defp get_adapter(:http), do: Dlex.Adapters.HTTP
  # Add possibility to specify custom adapter
  defp get_adapter(custom_adapter), do: custom_adapter

  # Implement calls for DBConnection Protocol

  @impl true
  def ping(%{adapter: adapter, channel: channel} = state) do
    case Adapter.ping(adapter, channel) do
      {:ok, channel} -> {:ok, %{state | channel: channel}}
      {:error, reason, channel} -> {:disconnect, reason, %{state | channel: channel}}
    end
  end

  @impl true
  def checkout(state) do
    {:ok, state}
  end

  @impl true
  def checkin(state) do
    {:ok, state}
  end

  @impl true
  def disconnect(_error, %{adapter: adapter, channel: channel} = _state) do
    Adapter.disconnect(adapter, channel)
  end

  ## Transaction API

  @impl true
  def handle_begin(opts, state) do
    best_effort? = Keyword.get(opts, :best_effort, false)
    read_only? = Keyword.get(opts, :read_only, false) or best_effort?

    {:ok, nil,
     %{
       state
       | txn_context: %TxnContext{},
         txn_aborted?: false,
         txn_mutated?: false,
         txn_read_only?: read_only?,
         txn_best_effort?: best_effort?
     }}
  end

  @impl true
  def handle_rollback(opts, state), do: finish_txn(state, :rollback, opts)

  @impl true
  def handle_commit(opts, state), do: finish_txn(state, :commit, opts)

  defp finish_txn(%{txn_aborted?: true} = state, txn_result, _opts) do
    {:error, %Error{action: txn_result, reason: :aborted}, state}
  end

  defp finish_txn(state, txn_result, opts) do
    txn_context = state.txn_context
    txn_read_only? = state.txn_read_only?
    txn_mutated? = state.txn_mutated?

    state = %{
      state
      | txn_context: nil,
        txn_mutated?: false,
        txn_read_only?: false,
        txn_best_effort?: false
    }

    timeout = Keyword.get(opts, :timeout, @timeout)
    txn_context = %{txn_context | aborted: txn_result != :commit}

    if txn_read_only? or not txn_mutated? do
      {:ok, txn_context, state}
    else
      commit_or_abort(state, txn_context, txn_result, timeout)
    end
  end

  defp commit_or_abort(
         %{adapter: adapter, channel: channel, json: json_lib} = state,
         txn_context,
         txn_result,
         timeout
       ) do
    case Adapter.commit_or_abort(adapter, channel, txn_context, json_lib, timeout: timeout) do
      {:ok, txn} ->
        {:ok, txn, state}

      {:ok, txn, channel} ->
        {:ok, txn, %{state | channel: channel}}

      {:error, reason} ->
        error = %Error{action: txn_result, reason: reason}
        {state_on_error(reason), error, state}

      {:error, reason, channel} ->
        error = %Error{action: txn_result, reason: reason}
        {state_on_error(reason), error, %{state | channel: channel}}
    end
  end

  ## Query API

  @impl true
  def handle_prepare(
        query,
        opts,
        %{
          json: json_lib,
          txn_context: txn_context,
          txn_read_only?: txn_read_only?,
          txn_best_effort?: txn_best_effort?
        } = state
      ) do
    read_only? = txn_read_only? or Keyword.get(opts, :read_only, false)
    best_effort? = txn_best_effort? or Keyword.get(opts, :best_effort, false)

    {:ok,
     %{
       query
       | json: json_lib,
         txn_context: txn_context,
         read_only: read_only?,
         best_effort: best_effort?
     }, state}
  end

  @impl true
  def handle_execute(%Query{} = query, request, opts, state) do
    %{adapter: adapter, channel: channel} = state
    timeout = Keyword.get(opts, :timeout, Keyword.get(state.opts, :timeout))

    adapter_opts =
      opts
      |> Keyword.take([
        :deadline,
        :metadata,
        :return_headers,
        :compressor,
        :accepted_compressors,
        :dlex_access_jwt
      ])
      |> Keyword.put(:timeout, timeout)

    if state.txn_read_only? and query.type == Type.Mutation do
      error = %Error{action: :execute, reason: :read_only_transaction}
      {:error, error, state}
    else
      state =
        if state.txn_context != nil and query.type == Type.Mutation,
          do: %{state | txn_mutated?: true},
          else: state

      execute_query(adapter, channel, query, request, adapter_opts, state)
    end
  end

  defp execute_query(adapter, channel, query, request, opts, state) do
    case Type.execute(adapter, channel, query, request, opts) do
      {:ok, result} ->
        {:ok, query, result, check_txn(state, result)}

      {:ok, result, channel} ->
        {:ok, query, result, check_txn(%{state | channel: channel}, result)}

      {:error, reason} ->
        error = %Error{action: :execute, reason: reason}
        {state_on_error(reason), error, check_abort(state, reason)}

      {:error, reason, channel} ->
        error = %Error{action: :execute, reason: reason}
        {state_on_error(reason), error, check_abort(%{state | channel: channel}, reason)}
    end
  end

  defp check_txn(state, result) do
    case result do
      %{txn: %TxnContext{} = txn_context} -> merge_txn(state, txn_context)
      %{context: %TxnContext{} = txn_context} -> merge_txn(state, txn_context)
      _ -> state
    end
  end

  defp check_abort(state, %GRPC.RPCError{status: 10}), do: %{state | txn_aborted?: true}
  defp check_abort(state, _error), do: state

  defp merge_txn(%{txn_context: nil} = state, _), do: state

  defp merge_txn(%{txn_context: %TxnContext{} = txn_context} = state, new_txn_context) do
    %{start_ts: start_ts, keys: keys, preds: preds} = txn_context
    %{start_ts: new_start_ts, keys: new_keys, preds: new_preds, hash: new_hash} = new_txn_context
    start_ts = if start_ts == 0, do: new_start_ts, else: start_ts
    keys = keys ++ new_keys
    preds = preds ++ new_preds

    %{
      state
      | txn_context: %{txn_context | start_ts: start_ts, keys: keys, preds: preds, hash: new_hash}
    }
  end

  @impl true
  def handle_close(_query, _opts, state) do
    {:ok, nil, state}
  end

  @impl true
  def handle_status(_opts, state) do
    {:idle, state}
  end

  ## Stream API

  @impl true
  def handle_declare(query, _params, _opts, state) do
    {:ok, query, nil, state}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, state) do
    {:halt, nil, state}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:ok, nil, state}
  end

  defp state_on_error(%GRPC.RPCError{message: ":noproc"}), do: :disconnect
  defp state_on_error(%GRPC.RPCError{message: ":shutdown" <> _}), do: :disconnect
  defp state_on_error(_), do: :error
end
