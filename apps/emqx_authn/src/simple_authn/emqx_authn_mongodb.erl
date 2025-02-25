%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authn_mongodb).

-include("emqx_authn.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).
-behaviour(emqx_authentication).

-export([ namespace/0
        , roots/0
        , fields/1
        ]).

-export([ refs/0
        , create/1
        , update/2
        , authenticate/2
        , destroy/1
        ]).

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

namespace() -> "authn:password-based:mongodb".

roots() ->
    [ {config, {union, [ hoconsc:mk(standalone)
                       , hoconsc:mk('replica-set')
                       , hoconsc:mk('sharded-cluster')
                       ]}}
    ].

fields(standalone) ->
    common_fields() ++ emqx_connector_mongo:fields(single);

fields('replica-set') ->
    common_fields() ++ emqx_connector_mongo:fields(rs);

fields('sharded-cluster') ->
    common_fields() ++ emqx_connector_mongo:fields(sharded).

common_fields() ->
    [ {mechanism,               {enum, ['password-based']}}
    , {backend,                 {enum, [mongodb]}}
    , {collection,              fun collection/1}
    , {selector,                fun selector/1}
    , {password_hash_field,     fun password_hash_field/1}
    , {salt_field,              fun salt_field/1}
    , {is_superuser_field,      fun is_superuser_field/1}
    , {password_hash_algorithm, fun password_hash_algorithm/1}
    , {salt_position,           fun salt_position/1}
    ] ++ emqx_authn_schema:common_fields().

collection(type) -> binary();
collection(_) -> undefined.

selector(type) -> map();
selector(_) -> undefined.

password_hash_field(type) -> binary();
password_hash_field(_) -> undefined.

salt_field(type) -> binary();
salt_field(nullable) -> true;
salt_field(_) -> undefined.

is_superuser_field(type) -> binary();
is_superuser_field(nullable) -> true;
is_superuser_field(_) -> undefined.

password_hash_algorithm(type) -> {enum, [plain, md5, sha, sha256, sha512, bcrypt]};
password_hash_algorithm(default) -> sha256;
password_hash_algorithm(_) -> undefined.

salt_position(type) -> {enum, [prefix, suffix]};
salt_position(default) -> prefix;
salt_position(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
    [ hoconsc:ref(?MODULE, standalone)
    , hoconsc:ref(?MODULE, 'replica-set')
    , hoconsc:ref(?MODULE, 'sharded-cluster')
    ].

create(#{ selector := Selector
        , '_unique' := Unique
        } = Config) ->
    NSelector = parse_selector(Selector),
    State = maps:with([ collection
                      , password_hash_field
                      , salt_field
                      , is_superuser_field
                      , password_hash_algorithm
                      , salt_position
                      , '_unique'], Config),
    NState = State#{selector => NSelector},
    case emqx_resource:create_local(Unique, emqx_connector_mongo, Config) of
        {ok, already_created} ->
            {ok, NState};
        {ok, _} ->
            {ok, NState};
        {error, Reason} ->
            {error, Reason}
    end.

update(Config, State) ->
    case create(Config) of
        {ok, NewState} ->
            ok = destroy(State),
            {ok, NewState};
        {error, Reason} ->
            {error, Reason}
    end.

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(#{password := Password} = Credential,
             #{ collection := Collection
              , selector := Selector0
              , '_unique' := Unique
              } = State) ->
    try
        Selector1 = replace_placeholders(Selector0, Credential),
        Selector2 = normalize_selector(Selector1),
        case emqx_resource:query(Unique, {find_one, Collection, Selector2, #{}}) of
            undefined -> ignore;
            {error, Reason} ->
                ?LOG(error, "['~s'] Query failed: ~p", [Unique, Reason]),
                ignore;
            Doc ->
                case check_password(Password, Doc, State) of
                    ok ->
                        {ok, #{is_superuser => is_superuser(Doc, State)}};
                    {error, {cannot_find_password_hash_field, PasswordHashField}} ->
                        ?LOG(error, "['~s'] Can't find password hash field: ~s", [Unique, PasswordHashField]),
                        {error, bad_username_or_password};
                    {error, Reason} ->
                        {error, Reason}
                end
        end
    catch
        error:Error ->
            ?LOG(warning, "The following error occurred in '~s' during authentication: ~p", [Unique, Error]),
            ignore
    end.

destroy(#{'_unique' := Unique}) ->
    _ = emqx_resource:remove_local(Unique),
    ok.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

parse_selector(Selector) ->
    NSelector = emqx_json:encode(Selector),
    Tokens = re:split(NSelector, "(" ++ ?RE_PLACEHOLDER ++ ")", [{return, binary}, group, trim]),
    parse_selector(Tokens, []).

parse_selector([], Acc) ->
    lists:reverse(Acc);
parse_selector([[Constant, Placeholder] | Tokens], Acc) ->
    parse_selector(Tokens, [{placeholder, Placeholder}, {constant, Constant} | Acc]);
parse_selector([[Constant] | Tokens], Acc) ->
    parse_selector(Tokens, [{constant, Constant} | Acc]).

replace_placeholders(Selector, Credential) ->
    lists:map(fun({constant, Constant}) ->
                  Constant;
                 ({placeholder, Placeholder}) ->
                  case emqx_authn_utils:replace_placeholder(Placeholder, Credential) of
                      undefined -> error({cannot_get_variable, Placeholder});
                      Value -> Value
                  end
              end, Selector).

normalize_selector(Selector) ->
    emqx_json:decode(iolist_to_binary(Selector), [return_maps]).

check_password(undefined, _Selected, _State) ->
    {error, bad_username_or_password};
check_password(Password,
               Doc,
               #{password_hash_algorithm := bcrypt,
                 password_hash_field := PasswordHashField}) ->
    case maps:get(PasswordHashField, Doc, undefined) of
        undefined ->
            {error, {cannot_find_password_hash_field, PasswordHashField}};
        Hash ->
            case {ok, Hash} =:= bcrypt:hashpw(Password, Hash) of
                true -> ok;
                false -> {error, bad_username_or_password}
            end
    end;
check_password(Password,
               Doc,
               #{password_hash_algorithm := Algorithm,
                 password_hash_field := PasswordHashField,
                 salt_position := SaltPosition} = State) ->
    case maps:get(PasswordHashField, Doc, undefined) of
        undefined ->
            {error, {cannot_find_password_hash_field, PasswordHashField}};
        Hash ->
            Salt = case maps:get(salt_field, State, undefined) of
                       undefined -> <<>>;
                       SaltField -> maps:get(SaltField, Doc, <<>>)
                   end,
            case Hash =:= hash(Algorithm, Password, Salt, SaltPosition) of
                true -> ok;
                false -> {error, bad_username_or_password}
            end
    end.

is_superuser(Doc, #{is_superuser_field := IsSuperuserField}) ->
    maps:get(IsSuperuserField, Doc, false);
is_superuser(_, _) ->
    false.

hash(Algorithm, Password, Salt, prefix) ->
    emqx_passwd:hash(Algorithm, <<Salt/binary, Password/binary>>);
hash(Algorithm, Password, Salt, suffix) ->
    emqx_passwd:hash(Algorithm, <<Password/binary, Salt/binary>>).
