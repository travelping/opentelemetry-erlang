%%%------------------------------------------------------------------------
%% Copyright 2020, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc Resource detectors are responsible for reading in attributes about
%% the runtime environment of a node (such as an environment variable or
%% some metadata endpoint provided by a cloud host) and returning a
%% `otel_resource:t()' made from those attributes.
%%
%% The state machine will spawn a process for each detector and collect the
%% results of running each and merge in the order they are defined. Once in
%% the `ready' state it will reply to `get_resource' calls with the final
%% `otel_resource:t()'.
%% @end
%%%-------------------------------------------------------------------------
-module(otel_resource_detector).

-behaviour(gen_statem).

-export([start_link/1,
         get_resource/0,
         get_resource/1]).

-export([init/1,
         callback_mode/0,
         handle_event/4]).

-callback get_resource(term()) -> otel_resource:t().

-type detector() :: module() | {module(), term()}.

-include_lib("kernel/include/logger.hrl").
-include("otel_resource.hrl").

-record(data, {resource         :: otel_resource:t(),
               detectors        :: [detector()],
               detector_timeout :: integer()}).

start_link(Opts) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [Opts], []).

get_resource() ->
    get_resource(6000).

get_resource(Timeout) ->
    try gen_statem:call(?MODULE, get_resource, Timeout)
    catch
        exit:{timeout, _} ->
            %% TODO: should we return an error instead?
            %% returning an empty resource ensures we continue on and
            %% don't crash anything depending on the returned resource
            %% but could mean we have an empty resource while the
            %% gen_server later has a full resourced
            otel_resource:create([])
    end.

init([Opts]) ->
    process_flag(trap_exit, true),

    Detectors = proplists:get_value(resource_detectors, Opts, []),
    DetectorTimeout = proplists:get_value(resource_detectors_timeout, Opts, 5000),

    {ok, collecting, #data{resource=otel_resource:create([]),
                           detectors=Detectors,
                           detector_timeout=DetectorTimeout},
     [{next_event, internal, spawn_detectors}]}.

callback_mode() ->
    [handle_event_function, state_enter].

handle_event(enter, _, ready, Data=#data{resource=Resource}) ->
    NewResource = required_attributes(Resource),
    {keep_state, Data#data{resource=NewResource}};
handle_event(enter, _, _, _) ->
    keep_state_and_data;
handle_event(internal, spawn_detectors, collecting, Data=#data{detectors=Detectors}) ->
    %% merging must be done in a specific order so Refs are kept in a list
    ToCollectRefs = spawn_detectors(Detectors),
    {next_state, next_state(ToCollectRefs), Data, [state_timeout(Data)]};
handle_event(info, {'EXIT', Pid, _}, {collecting, [{_, Pid, Detector} | Rest]}, Data) ->
    ?LOG_WARNING("detector ~p crashed while executing", [Detector]),
    {next_state, next_state(Rest), Data, [state_timeout(Data)]};

handle_event(info, {resource, Ref, Resource}, {collecting, [{Ref, _, _} | Rest]},
             Data=#data{resource=CurrentResource}) ->
    NewResource = otel_resource:merge(CurrentResource, Resource),
    {next_state, next_state(Rest), Data#data{resource=NewResource}, state_timeout(Data)};
handle_event(state_timeout, resource_detector_timeout, {collecting, [{_, Pid, Detector} | Rest]}, Data) ->
    ?LOG_WARNING("detector ~p timed out while executing", [Detector]),
    %% may still have an EXIT in the mailbox but with `unlink' we might not
    erlang:unlink(Pid),
    erlang:exit(Pid, kill),
    {next_state, next_state(Rest), Data, state_timeout(Data)};
handle_event(info, _, _, _Data) ->
    %% merging resources must be done in order, so postpone the message
    %% if it isn't the head of the list
    {keep_state_and_data, [postpone]};

handle_event({call, From}, get_resource, ready, #data{resource=Resource}) ->
    {keep_state_and_data, [{reply, From, Resource}]};
handle_event({call, _From}, get_resource, _, _Data) ->
    %% can't get the resource until all detectors have completed
    %% at which point this statem will be in the `ready' state
    {keep_state_and_data, [postpone]};
handle_event(_, _, ready, _) ->
    %% if in `ready' state get rid of all the postpones messages in
    %% the mailbox that were postponed. Could be EXIT's or late resource
    %% messages
    keep_state_and_data.

%%

%% go to the `ready' state if the list of detectors to collect for is empty
next_state([]) ->
    ready;
next_state(List) ->
    {collecting, List}.

state_timeout(#data{detector_timeout=DetectorTimeout}) ->
    {state_timeout, DetectorTimeout, resource_detector_timeout}.

spawn_detectors(Detectors) ->
    lists:map(fun(Detector) ->
                      Ref = erlang:make_ref(),
                      Pid = spawn_detector(Detector, Ref),
                      {Ref, Pid, Detector}
              end, Detectors).

spawn_detector(Detector={Module, Config}, Ref) ->
    Self = self(),
    erlang:spawn_link(fun() ->
                              try Module:get_resource(Config) of
                                  Resource ->
                                      Self ! {resource, Ref, Resource}
                              catch
                                  C:T:S ->
                                      ?LOG_WARNING("caught exception while detector ~p was "
                                                   "executing: class=~p exception=~p stacktrace=~p",
                                                   [Detector, C, T, S]),
                                      %% TODO: log about detector's exception
                                      Self ! {resource, Ref, otel_resource:create([])}
                              end
                      end);
spawn_detector(Module, Ref) ->
    spawn_detector({Module, []}, Ref).

required_attributes(Resource) ->
    ProgName = prog_name(),
    ProcessResource = otel_resource:create([{?PROCESS_EXECUTABLE_NAME, ProgName} | process_attributes()]),
    Resource1 = otel_resource:merge(Resource, ProcessResource),

    Attributes = otel_resource:attributes(Resource1),
    case lists:keyfind(?SERVICE_NAME, 1, Attributes) of
        false ->
            %% if service.name isn't set we try finding the release name
            %% if no release name we use the default
            DefaultServiceResource =
                case find_release() of
                    {RelName, RelVsn} when RelName =/= false ->
                        otel_resource:create([{?SERVICE_NAME, RelName} |
                                              case RelVsn of
                                                  false -> [];
                                                  _ -> [{?SERVICE_VERSION, RelVsn}]
                                              end]);
                    _ ->
                        otel_resource:create([{?SERVICE_NAME, "unknown_service:" ++ ProgName}])
                end,


            otel_resource:merge(Resource1,  DefaultServiceResource);
        _ ->
            Resource1
    end.

process_attributes() ->
    OtpVsn = otp_vsn(),
    ErtsVsn = erts_vsn(),
    [{?PROCESS_RUNTIME_NAME, emulator()},
     {?PROCESS_RUNTIME_VERSION, ErtsVsn},
     {?PROCESS_RUNTIME_DESCRIPTION, runtime_description(OtpVsn, ErtsVsn)}].

runtime_description(OtpVsn, ErtsVsn) ->
    io_lib:format("Erlang/OTP ~s erts-~s", [OtpVsn, ErtsVsn]).

erts_vsn() ->
    erlang:system_info(version).

otp_vsn() ->
    erlang:system_info(otp_release).

emulator() ->
    erlang:system_info(machine).

prog_name() ->
    %% PROGNAME is an OS variable set by `erl' and the `relx' start script
    os_or_default("PROGNAME", "erl").

os_or_default(EnvVar, Default) ->
    case os:getenv(EnvVar) of
        false ->
            Default;
        Value ->
            Value
    end.

find_release() ->
    try release_handler:which_releases(permanent) of
        [{RelName, RelVsn, _Apps, permanent} | _] ->
            {RelName, RelVsn}
    catch
        %% can happen if `release_handler' isn't availabe
        %% or its process isn't started
        _:_ ->
            {os:getenv("REL_NAME"), os:getenv("REL_VSN")}
    end.
