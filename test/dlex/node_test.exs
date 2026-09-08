defmodule Dlex.NodeTest do
  use ExUnit.Case

  alias Dlex.User

  defmodule VectorDocument do
    use Dlex.Node

    schema "vector_document" do
      field :body, :string, index: ["fulltext"]
      field :embedding, :float32vector, index: ["hnsw(metric:\"cosine\", exponent:\"4\")"]
    end
  end

  describe "schema generation" do
    test "basic" do
      assert "user" == User.__schema__(:source)
      assert :string == User.__schema__(:type, :name)
      assert :integer == User.__schema__(:type, :age)
      assert [:name, :age, :friends, :location] == User.__schema__(:fields)
    end

    test "alter" do
      assert %{
               "schema" => [
                 %{
                   "index" => true,
                   "predicate" => "user.name",
                   "tokenizer" => ["term"],
                   "type" => "string"
                 },
                 %{"predicate" => "user.age", "type" => "int"},
                 %{"predicate" => "user.friends", "type" => "[uid]"},
                 %{"predicate" => "user.location", "type" => "geo"}
               ],
               "types" => [
                 %{
                   "fields" => [
                     %{"name" => "user.location", "type" => "geo"},
                     %{"name" => "user.friends", "type" => "[uid]"},
                     %{"name" => "user.age", "type" => "int"},
                     %{"name" => "user.name", "type" => "string"}
                   ],
                   "name" => "user"
                 }
               ]
             } == User.__schema__(:alter)
    end

    test "transformation callbacks" do
      assert "user.name" == User.__schema__(:field, :name)
      assert {:name, :string} == User.__schema__(:field, "user.name")
    end

    test "fulltext and HNSW indexes" do
      assert %{
               "schema" => [
                 %{
                   "index" => true,
                   "predicate" => "vector_document.body",
                   "tokenizer" => ["fulltext"],
                   "type" => "string"
                 },
                 %{
                   "index" => true,
                   "predicate" => "vector_document.embedding",
                   "tokenizer" => ["hnsw(metric:\"cosine\", exponent:\"4\")"],
                   "type" => "float32vector"
                 }
               ],
               "types" => [
                 %{
                   "fields" => [
                     %{"name" => "vector_document.embedding", "type" => "float32vector"},
                     %{"name" => "vector_document.body", "type" => "string"}
                   ],
                   "name" => "vector_document"
                 }
               ]
             } == VectorDocument.__schema__(:alter)

      assert {:embedding, :float32vector} =
               VectorDocument.__schema__(:field, "vector_document.embedding")

      changeset =
        Ecto.Changeset.cast(%VectorDocument{}, %{embedding: [1.0, 0.0]}, [:embedding])

      assert changeset.valid?

      assert %{"vector_document.embedding" => "[1.0, 0.0]"} =
               Dlex.Repo.encode(%VectorDocument{embedding: [1.0, 0.0]})
    end
  end
end
