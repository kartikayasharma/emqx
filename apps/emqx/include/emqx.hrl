%%--------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-ifndef(EMQ_X_HRL).
-define(EMQ_X_HRL, true).

%%--------------------------------------------------------------------
%% Common
%%--------------------------------------------------------------------

-define(Otherwise, true).

-define(COMMON_SHARD, emqx_common_shard).
-define(SHARED_SUB_SHARD, emqx_shared_sub_shard).
-define(MOD_DELAYED_SHARD, emqx_delayed_shard).
-define(CM_SHARD, emqx_cm_shard).

%%--------------------------------------------------------------------
%% Banner
%%--------------------------------------------------------------------

-define(PROTOCOL_VERSION, "MQTT/5.0").

-define(ERTS_MINIMUM_REQUIRED, "10.0").

%%--------------------------------------------------------------------
%% Topics' prefix: $SYS | $queue | $share
%%--------------------------------------------------------------------

%% System topic
-define(SYSTOP, <<"$SYS/">>).

%% Queue topic
-define(QUEUE,  <<"$queue/">>).

%%--------------------------------------------------------------------
%% Message and Delivery
%%--------------------------------------------------------------------

-record(subscription, {topic, subid, subopts}).

%% See 'Application Message' in MQTT Version 5.0
-record(message, {
          %% Global unique message ID
          id :: binary(),
          %% Message QoS
          qos = 0,
          %% Message from
          from :: atom() | binary(),
          %% Message flags
          flags = #{} :: emqx_types:flags(),
          %% Message headers. May contain any metadata. e.g. the
          %% protocol version number, username, peerhost or
          %% the PUBLISH properties (MQTT 5.0).
          headers = #{} :: emqx_types:headers(),
          %% Topic that the message is published to
          topic :: emqx_types:topic(),
          %% Message Payload
          payload :: emqx_types:payload(),
          %% Timestamp (Unit: millisecond)
          timestamp :: integer()
         }).

-record(delivery, {
          sender  :: pid(),      %% Sender of the delivery
          message :: #message{}  %% The message delivered
        }).

%%--------------------------------------------------------------------
%% Route
%%--------------------------------------------------------------------

-define(ROUTE_SHARD, route_shard).


-define(RULE_ENGINE_SHARD, emqx_rule_engine_shard).

-record(route, {
          topic :: binary(),
          dest  :: node() | {binary(), node()}
         }).

%%--------------------------------------------------------------------
%% Plugin
%%--------------------------------------------------------------------

-record(plugin, {
          name           :: atom(),
          dir            :: string() | undefined,
          descr          :: string(),
          vendor         :: string() | undefined,
          active = false :: boolean(),
          info   = #{}   :: map()
        }).

%%--------------------------------------------------------------------
%% Command
%%--------------------------------------------------------------------

-record(command, {
          name      :: atom(),
          action    :: atom(),
          args = [] :: list(),
          opts = [] :: list(),
          usage     :: string(),
          descr     :: string()
        }).

%%--------------------------------------------------------------------
%% Banned
%%--------------------------------------------------------------------

-record(banned, {
          who    :: {clientid,  binary()}
                  | {peerhost, inet:ip_address()}
                  | {username,   binary()},
          by     :: binary(),
          reason :: binary(),
          at     :: integer(),
          until  :: integer()
        }).

-endif.

%%--------------------------------------------------------------------
%% Authentication
%%--------------------------------------------------------------------

-record(authenticator,
        { id :: binary()
        , provider :: module()
        , enable :: boolean()
        , state :: map()
        }).

-record(chain,
        { name :: atom()
        , authenticators :: [#authenticator{}]
        }).