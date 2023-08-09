% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% Scanner plugin server.
%
% This is gen_server starts, stops and reschedules plugin processes.
%

-module(couch_scanner_server).

-export([
    start_link/0
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-define(TIMEOUT, 1000).
-define(ERROR_PENALTY_BASE_SEC, 60).
-define(ERROR_THRESHOLD_SEC, 24 * 3600).

-record(sched, {
    error_time = 0,
    error_count = 0,
    reschedule = 0
}).

-record(st, {
    pids = #{},
    scheduling = #{},
    tref
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_Args) ->
    process_flag(trap_exit, true),
    {ok, #st{}, ?TIMEOUT + rand:uniform(?TIMEOUT)}.

terminate(_Reason, #st{pids = Pids} = St) ->
    ToStop = maps:keys(Pids),
    lists:foldl(fun stop_plugin/2, St, ToStop),
    ok.

handle_call(Msg, _From, #st{} = St) ->
    couch_log:error("~p : unknown call ~p", [?MODULE, Msg]),
    {reply, {error, {invalid_call, Msg}}, St}.

handle_cast(Msg, #st{} = St) ->
    couch_log:error("~p : unknown cast ~p", [?MODULE, Msg]),
    {noreply, St}.

handle_info(timeout, #st{} = St) ->
    St1 = start_stop_cfg(St),
    {noreply, schedule_timeout(St1)};
handle_info({'EXIT', Pid, Reason}, #st{pids = Pids} = St) ->
    case maps:filter(fun(_, P) -> P =:= Pid end, Pids) of
        Map when map_size(Map) == 1 ->
            [{Id, Pid}] = maps:to_list(Map),
            St1 = St#st{pids = maps:remove(Id, Pids)},
            {noreply, handle_exit(Id, Reason, St1)};
        Map when map_size(Map) == 0 ->
            {noreply, St}
    end;
handle_info(Msg, St) ->
    couch_log:error("~p : unknown info message ~p", [?MODULE, Msg]),
    {noreply, St}.

start_stop_cfg(#st{pids = Pids, scheduling = Scheduling} = St) ->
    PluginIds = plugins(),
    RunningIds = maps:keys(Pids),
    ToStart = PluginIds -- RunningIds,
    ToStop = RunningIds -- PluginIds,
    St1 = lists:foldl(fun stop_plugin/2, St, ToStop),
    lists:foreach(fun couch_scanner_checkpoint:reset/1, ToStop),
    ToRemove = maps:keys(Scheduling) -- PluginIds,
    St2 = St1#st{scheduling = maps:without(ToRemove, Scheduling)},
    lists:foldl(fun start_plugin/2, St2, ToStart).

stop_plugin(Id, #st{pids = Pids} = St) ->
    {Pid, Pids1} = maps:take(Id, Pids),
    ok = couch_scanner_plugin:stop(Pid),
    St#st{pids = Pids1}.

start_plugin(Id, #st{pids = Pids, scheduling = Scheduling} = St) ->
    Sched = maps:get(Id, Scheduling, #sched{}),
    case tsec() >= start_sec(Sched) of
        true ->
            {ok, Pid} = couch_scanner_plugin:start_link(Id),
            Pids1 = Pids#{Id => Pid},
            Scheduling1 = Scheduling#{Id => Sched},
            St#st{pids = Pids1, scheduling = Scheduling1};
        false ->
            St
    end.

plugins() ->
    Fun = fun
        ({K, "true"}, Acc) ->
            FullName = "couch_scanner_plugin_" ++ K,
            [list_to_binary(FullName) | Acc];
        ({_, _}, Acc) ->
            Acc
    end,
    lists:foldl(Fun, [], config:get("couch_scanner_plugins")).

handle_exit(Id, Reason, #st{} = St) ->
    #st{scheduling = Scheduling} = St,
    #{Id := Sched} = Scheduling,
    Sched1 =
        case Reason of
            {shutdown, {reschedule, TSec}} ->
                Sched#sched{
                    error_time = 0,
                    error_count = 0,
                    reschedule = TSec
                };
            Norm when Norm == shutdown; Norm == normal ->
                Sched#sched{
                    error_time = 0,
                    error_count = 0,
                    reschedule = infinity
                };
            Error ->
                couch_log:error("~p : ~p error ~p", [?MODULE, Id, Error]),
                #sched{error_time = ESec, error_count = ErrCnt} = Sched,
                NowSec = tsec(),
                case NowSec - ESec =< ?ERROR_THRESHOLD_SEC of
                    true ->
                        Sched#sched{
                            error_time = NowSec,
                            error_count = ErrCnt + 1
                        };
                    false ->
                        Sched#sched{
                            error_time = NowSec,
                            error_count = 1
                        }
                end
        end,
    St#st{scheduling = Scheduling#{Id := Sched1}}.

start_sec(#sched{} = Sched) ->
    #sched{error_count = ErrorCount, reschedule = ReschedSec} = Sched,
    case ErrorCount of
        Val when is_integer(Val), Val > 0 ->
            BackoffSec = ?ERROR_PENALTY_BASE_SEC * (1 bsl (ErrorCount - 1)),
            max(tsec() + BackoffSec, ReschedSec);
        0 ->
            ReschedSec
    end.

tsec() ->
    erlang:system_time(second).

schedule_timeout(#st{tref = TRef} = St) ->
    case TRef of
        undefined -> ok;
        _ when is_reference(TRef) -> erlang:cancel_timer(TRef)
    end,
    TRef1 = erlang:send_after(?TIMEOUT, self(), timeout),
    St#st{tref = TRef1}.
