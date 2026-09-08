defmodule Dlex.AuthTest do
  use ExUnit.Case

  test "returns an empty JWT bundle before login" do
    assert Dlex.get_jwt(self()) == %{access_jwt: "", refresh_jwt: ""}
  end

  test "exposes the retained JWT bundle" do
    table = :dlex_auth_tokens
    key = self()
    jwt = %{access_jwt: "access-token", refresh_jwt: "refresh-token"}

    Dlex.get_jwt(key)
    :ets.insert(table, {key, jwt})

    assert Dlex.get_jwt(key) == jwt
  after
    if :ets.whereis(:dlex_auth_tokens) != :undefined do
      :ets.delete(:dlex_auth_tokens, self())
    end
  end

  test "relogin without a retained refresh JWT fails locally" do
    assert {:error, %Dlex.Error{action: :login, reason: "refresh jwt should not be empty"}} =
             Dlex.relogin(self())
  end
end
