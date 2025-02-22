%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc This supervisor manages workers which should never need a restart
%% due to config changes or when joining a cluster.
-module(emqx_machine_sup).

-behaviour(supervisor).

-export([ start_link/0
        ]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    GlobalGC = child_worker(emqx_global_gc, [], permanent),
    Terminator = child_worker(emqx_machine_terminator, [], transient),
    ClusterRpc = child_worker(emqx_cluster_rpc, [], permanent),
    ClusterHandler = child_worker(emqx_cluster_rpc_handler, [], permanent),
    Children = [GlobalGC, Terminator, ClusterRpc, ClusterHandler],
    SupFlags = #{strategy => one_for_one,
                 intensity => 100,
                 period => 10
                },
    {ok, {SupFlags, Children}}.

child_worker(M, Args, Restart) ->
    #{id       => M,
      start    => {M, start_link, Args},
      restart  => Restart,
      shutdown => 5000,
      type     => worker,
      modules  => [M]
     }.
