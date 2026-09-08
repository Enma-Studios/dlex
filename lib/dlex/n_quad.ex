defmodule Dlex.NQuad do
  @moduledoc """
  Constructors for structured Dgraph NQuads and facets.

  Structured NQuad mutations are supported by the gRPC transport.
  """

  alias Dlex.Api.{Facet, NQuad, Value}

  @doc """
  Build a string-valued NQuad.
  """
  def string(subject, predicate, value, opts \\ []) do
    nquad(subject, predicate, Keyword.merge(opts, object_value: %Value{val: {:str_val, value}}))
  end

  @doc """
  Build a UID-valued NQuad.
  """
  def uid(subject, predicate, object_id, opts \\ []) do
    nquad(subject, predicate, Keyword.merge(opts, object_id: object_id))
  end

  @doc """
  Build an integer-valued NQuad.
  """
  def integer(subject, predicate, value, opts \\ []) do
    nquad(subject, predicate, Keyword.merge(opts, object_value: %Value{val: {:int_val, value}}))
  end

  @doc """
  Build a floating-point-valued NQuad.
  """
  def float(subject, predicate, value, opts \\ []) do
    nquad(
      subject,
      predicate,
      Keyword.merge(opts, object_value: %Value{val: {:double_val, value}})
    )
  end

  @doc """
  Build a boolean-valued NQuad.
  """
  def boolean(subject, predicate, value, opts \\ []) do
    nquad(subject, predicate, Keyword.merge(opts, object_value: %Value{val: {:bool_val, value}}))
  end

  @doc """
  Build a default-valued NQuad.
  """
  def default_value(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:default_val, value}, opts)
  end

  @doc """
  Build a bytes-valued NQuad.
  """
  def bytes(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:bytes_val, value}, opts)
  end

  @doc """
  Build a date-valued NQuad from its protobuf-encoded bytes.
  """
  def date(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:date_val, value}, opts)
  end

  @doc """
  Build a datetime-valued NQuad from its protobuf-encoded bytes.
  """
  def datetime(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:datetime_val, value}, opts)
  end

  @doc """
  Build a geo-valued NQuad from its WKB bytes.
  """
  def geo(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:geo_val, value}, opts)
  end

  @doc """
  Build a password-valued NQuad.
  """
  def password(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:password_val, value}, opts)
  end

  @doc """
  Build a bigfloat-valued NQuad from its protobuf-encoded bytes.
  """
  def bigfloat(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:bigfloat_val, value}, opts)
  end

  @doc """
  Build a float32-vector NQuad from its protobuf-encoded bytes.
  """
  def vector(subject, predicate, value, opts \\ []) do
    value(subject, predicate, {:vfloat32_val, value}, opts)
  end

  @doc """
  Build an NQuad with any raw `Dlex.Api.Value` oneof field.
  """
  def value(subject, predicate, {field, value}, opts \\ [])
      when field in [
             :default_val,
             :bytes_val,
             :int_val,
             :bool_val,
             :str_val,
             :double_val,
             :geo_val,
             :date_val,
             :datetime_val,
             :password_val,
             :uid_val,
             :bigfloat_val,
             :vfloat32_val
           ] do
    nquad(subject, predicate, Keyword.merge(opts, object_value: %Value{val: {field, value}}))
  end

  @doc """
  Build a delete NQuad. With no `:object_id`, all values for the predicate are deleted.
  """
  def delete(subject, predicate, opts \\ []) do
    object =
      case Keyword.fetch(opts, :object_id) do
        {:ok, object_id} -> [object_id: object_id]
        :error -> [object_value: %Value{val: {:default_val, "_STAR_ALL"}}]
      end

    nquad(subject, predicate, Keyword.merge(opts, object))
  end

  @doc """
  Build a raw structured NQuad.
  """
  def nquad(subject, predicate, opts \\ []) do
    %NQuad{
      subject: subject,
      predicate: predicate,
      object_id: Keyword.get(opts, :object_id, ""),
      object_value: Keyword.get(opts, :object_value),
      lang: Keyword.get(opts, :lang, ""),
      facets: Keyword.get(opts, :facets, []),
      namespace: Keyword.get(opts, :namespace, 0)
    }
  end

  @doc """
  Build a string facet.
  """
  def string_facet(key, value), do: %Facet{key: key, value: value, val_type: :STRING}

  @doc """
  Build a boolean facet.
  """
  def boolean_facet(key, value), do: %Facet{key: key, value: to_string(value), val_type: :BOOL}

  @doc """
  Build an integer facet.
  """
  def integer_facet(key, value), do: %Facet{key: key, value: to_string(value), val_type: :INT}

  @doc """
  Build a floating-point facet.
  """
  def float_facet(key, value), do: %Facet{key: key, value: to_string(value), val_type: :FLOAT}
end
