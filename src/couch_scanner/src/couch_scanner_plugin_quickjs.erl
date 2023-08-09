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

-module(couch_scanner_plugin_quickjs).

-export([
    start/1,
    stop/1,
    checkpoint/1,
    db/2,
    ddoc/3,
    shard/2,
    doc_id/5,
    doc/4
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("mem3/include/mem3.hrl").

-record(st, {
    scan_id,
    qjs_proc,
    sm_proc
}).

-define(LOG(S, O), log(S, ?FUNCTION_NAME, O)).

start(undefined) ->
    St = #st{
        scan_id = scan_id()
    },
    ?LOG(St, #{start => new, st => St}),
    {ok, St};
start(#{} = JsonSt) ->
    #{<<"scan_id">> := ScanId} = JsonSt,
    St = #st{
        scan_id = ScanId
    },
    ?LOG(St, #{start => cont, st => St}),
    % {reschedule, TSec}
    {ok, St}.

stop(#st{} = St) ->
    ?LOG(St, #{}),
    % {reschedule, TSec}
    ok.

checkpoint(#st{} = St) ->
    ?LOG(St, #{}),
    {ok, #{<<"scan_id">> => St#st.scan_id}}.

db(#st{} = St, DbName) ->
    ?LOG(St, #{db => DbName}),
    {ok, St}.

ddoc(#st{} = St, DbName, #doc{} = DDoc) ->
    ?LOG(St, #{db => DbName, ddid => DDoc#doc.id}),
    % {skip, St} | {stop, St}
    {ok, St}.

shard(#st{} = St, #shard{} = Shard) ->
    ?LOG(St, #{sh => Shard#shard.name}),
    % {skip, St}
    {ok, St}.

doc_id(#st{} = St, DocId, DocIndex, DocTotal, Db) ->
    ?LOG(St, #{
        did => DocId,
        didx => DocIndex,
        dtot => DocTotal,
        db => couch_db:name(Db)
    }),
    % {skip, St} | {stop, St}
    {ok, St}.

doc(#st{} = St, Db, DDocs, #doc{} = Doc) ->
    DDocIds = [Id || #doc{id = Id} <- DDocs],
    ?LOG(St, #{did => Doc#doc.id, db => couch_db:name(Db), ddocs => DDocIds}),
    % {stop, St}
    {ok, St}.

% Private

qjs_proc() ->
    spawn_proc(couch_quickjs:mainjs_cmd()).

sm_proc() ->
    spawn_proc(os:getenv("COUCHDB_QUERY_SERVER_JAVASCRIPT")).

spawn_proc(Cmd) ->
    {ok, Pid} = couch_os_process:start_link(Cmd),
    unlink(Pid),
    make_proc(Pid).

teach_ddoc(Proc, DDoc) ->
    JsonDoc = couch_doc:to_json_obj(DDoc, []),
    DDocId = DDoc#doc.id,
    Prompt = [<<"ddoc">>, <<"new">>, DDocId, JsonDoc],
    true = couch_query_servers:proc_prompt(Proc, Prompt),
    ok.

make_proc(Pid) ->
    Proc = #proc{
        pid = Pid,
        prompt_fun = {couch_os_process, prompt},
        set_timeout_fun = {couch_os_process, set_timeout},
        stop_fun = {couch_os_process, stop}
    },
    {ok, Proc}.

log(#st{scan_id = SId}, FName, Obj = #{}) ->
    Report = maps:merge(#{sid => SId, f => atom_to_binary(FName)}, Obj),
    couch_log:report("scanner-quickjs", Report).

scan_id() ->
    TSec = integer_to_binary(erlang:system_time(second)),
    Rand = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(6))),
    <<TSec/binary, "-", Rand/binary>>.
