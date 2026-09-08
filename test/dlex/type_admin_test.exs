defmodule Dlex.TypeAdminTest do
  use ExUnit.Case

  alias Dlex.{Query, Type}

  test "decodes login JWT responses" do
    response = %Dlex.Api.Response{
      json:
        Dlex.Api.Jwt.encode(%Dlex.Api.Jwt{
          access_jwt: "access-token",
          refresh_jwt: "refresh-token"
        })
    }

    assert Type.decode(
             %Query{type: Type.Admin, statement: %{operation: :login}},
             response,
             []
           ) == %{
             access_jwt: "access-token",
             refresh_jwt: "refresh-token"
           }
  end

  test "encodes namespace and refresh-token login requests" do
    namespace_query = %Query{
      type: Type.Admin,
      statement: %{
        operation: :login,
        request: %Dlex.Api.LoginRequest{userid: "alice", password: "secret", namespace: 7}
      }
    }

    refresh_query = %Query{
      type: Type.Admin,
      statement: %{
        operation: :relogin,
        request: %Dlex.Api.LoginRequest{refresh_token: "refresh-token"}
      }
    }

    assert Type.encode(namespace_query, %{}, []) ==
             {:login, %Dlex.Api.LoginRequest{userid: "alice", password: "secret", namespace: 7}}

    assert Type.encode(refresh_query, %{}, []) ==
             {:relogin, %Dlex.Api.LoginRequest{refresh_token: "refresh-token"}}
  end

  test "normalizes response headers into metadata" do
    response = %Dlex.Api.Response{
      hdrs: %{
        "x-dgraph-test" => %Dlex.Api.ListOfString{value: ["one", "two"]}
      }
    }

    assert %{headers: %{"x-dgraph-test" => ["one", "two"]}} =
             Dlex.Type.Admin.metadata(response)
  end
end
