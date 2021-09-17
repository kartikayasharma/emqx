%%--------------------------------------------------------------------
%% Copyright (c) 2018-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_router_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Router helper
    Helper = #{id       => helper,
               start    => {emqx_router_helper, start_link, []},
               restart  => permanent,
               shutdown => 5000,
               type     => worker,
               modules  => [emqx_router_helper]},
    %% Router pool
    RouterPool = emqx_pool_sup:spec(router_pool,
                                    [router_pool, hash,
                                     {emqx_router, start_link, []}]),

    %% TODO: Should this be optional?

    %% We want this supervisor to own the table for restarts
    SessionTab = emqx_session_router:create_init_tab(),

    %% Resume worker sup
    ResumeSup = #{id => router_worker_sup,
                  start => {emqx_session_router_worker_sup, start_link, [SessionTab]},
                  restart => permanent,
                  shutdown => 2000,
                  type => supervisor,
                  modules => [emqx_session_router_worker_sup]},

    SessionRouterPool = emqx_pool_sup:spec(session_router_pool,
                                           [session_router_pool, hash,
                                            {emqx_session_router, start_link, []}]),
    {ok, {{one_for_all, 0, 1}, [Helper, RouterPool, ResumeSup, SessionRouterPool]}}.

