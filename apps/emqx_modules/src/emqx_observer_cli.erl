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

-module(emqx_observer_cli).

-export([ enable/0
        , disable/0
        ]).

-export([cmd/1]).


%%--------------------------------------------------------------------
%% enable/disable
%%--------------------------------------------------------------------
enable() ->
    emqx_ctl:register_command(observer, {?MODULE, cmd}, []).

disable() ->
    emqx_ctl:unregister_command(observer).

cmd(["status"]) ->
    observer_cli:start();

cmd(["bin_leak"]) ->
    [emqx_ctl:print("~p~n", [Row]) || Row <- recon:bin_leak(100)];

cmd(["load", Mod]) ->
    Module = list_to_existing_atom(Mod),
    Nodes = nodes(),
    Res = remote_load(Nodes, Module),
    emqx_ctl:print("Loaded ~p module on ~p on ~n", [Mod, Nodes, Res]);

cmd(_) ->
    emqx_ctl:usage([{"observer status",           "observer_cli:start()"},
                    {"observer bin_leak",         "recon:bin_leak(100)"},
                    {"observer load Mod",         "recon:remote_load(Mod) to all nodes"}]).

%% recon:remote_load/1 has a bug, when nodes() returns [], it is
%% taken by recon as a node name.
%% before OTP 23, the call returns a 'badrpc' tuple
%% after OTP 23, it crashes with 'badarg' error
remote_load([], _Module) -> ok;
remote_load(Nodes, Module) -> recon:remote_load(Nodes, Module).
