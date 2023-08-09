% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under1
% the License.

% Scanner plugin runner process
%
% This is the process which is spawned and run for each enabled plugin.
%
% A number of these processes are managed by the couch_scanner_server via
% start_link/1 and stop/1 functions. After a plugin runner is spawned, the only
% thing couch_scanner_server does is wait for it to exit.
%
% The plugin runner process may exit normally, crash, or exit with {shutdown,
% {reschedule, TSec}} if they want to reschedule to run again at some point the
% future (next day, a week later, etc).
%
% After the process starts, it will load and validate the plugin module. Then,
% it will start scanning all the dbs and docs on the local node. Shard ranges
% will be scanned only on one of the cluster nodes to avoid duplicating work.
% For instance, if there are 2 shard ranges, 0-7, 8-f, on nodes n1, n2, n3.
% Then, 0-7 might be scanned on n1 only, and 8-f on n3.
%
% The plugin API is the following:
%
%   start(undefined | #{}) -> {ok, St} | {reschedule, TSec}
%   stop(St) -> ok | {reschedule, TSec}
%   checkpoint(St) -> {ok, #{}}
%   db(St, DbName) -> {ok|skip|stop, St}
%   ddoc(St, DbName, #{} = DDoc) -> {ok|skip|stop, St}
%   shard(St, #shard{} = Shard) -> {ok|skip, St}
%   doc_id(St, DocId, DocIndex, DocTotal, Db) -> {ok|skip|stop, St}
%   doc(St, Db, DDocs, #{} = Doc) -> {ok|stop, St}
%
% The start/1 function is called when the plugin starts. It returns some
% context (St), which can be any Erlang term. All subsequent function calls
% will be called with the same St object, and may return an updated version of
% it. Most callbacks then take the same context object and may return an
% updated version of it.
%
% The checkpoint/1 callback is periodically called to checkpoint the scanning
% progress. The first time start/1 will be called with undefined, but if there
% is a checkpoint saved, it will be called with the saved checkpoint map value.
%
% The stop/1 callback is called when the scan has finished. If the scan finished
% successfully the checkpoint will be deleted. If the plugin is rescheduled to run
% again, it will start from a fresh state.
%
% As the cluster dbs, shards, ddocs and individual docs are discovered during
% scanning, the appropriate callbacks will be called. Most callbacks, besides
% the updated St object, can reply with ok, skip or stop tags. The meaning of
% those are:
%
%   * ok  - continue to the next object
%
%   * skip - skip the current object and don't scan its internal (ex: skip a db and
%     don't scan its ddocs, but continue with the next db)
%
%   * stop - stop scanning any remaining objects of that type (ex: don't scan any more dbs)
%

-module(couch_scanner_plugin).

-export([
    start_link/1,
    stop/1
]).

-export([
    init/1
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("mem3/include/mem3.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-define(CHECKPOINT_INTERVAL_SEC, 10).
-define(STOP_TIMEOUT_MSEC, 5000).

-record(st, {
    id,
    mod,
    pst,
    cursor,
    shards_db,
    db,
    ddocs = [],
    doc_total = 0,
    doc_index = 0,
    checkpoint_tsec = 0
}).

start_link(<<Id/binary>>) ->
    proc_lib:start_link(?MODULE, init, [Id]).

stop(Pid) when is_pid(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, _, _, _} -> ok
    after ?STOP_TIMEOUT_MSEC ->
        exit(Pid, kill),
        receive
            {'DOWN', Ref, _, _, _} -> ok
        end
    end,
    ok.

% Private functions

init(<<Id/binary>>) ->
    St = #st{id = Id, mod = plugin_mod(Id)},
    St1 = init_from_checkpoint(St),
    proc_lib:init_ack({ok, self()}),
    run(St1).

run(#st{id = Id} = St) ->
    St1 = scan_dbs(St),
    couch_scanner_checkpoint:reset(Id),
    stop_callback(St1).

scan_dbs(#st{cursor = Cursor} = St) ->
    DbsDbName = mem3_sync:shards_db(),
    ioq:set_io_priority({system, DbsDbName}),
    {ok, Db} = mem3_util:ensure_exists(DbsDbName),
    St1 = St#st{shards_db = Db},
    Opts = [{start_key, Cursor}],
    try
        {ok, St2} = couch_db:fold_docs(Db, fun scan_dbs_fold/2, St1, Opts),
        St2#st{shards_db = undefined}
    after
        couch_db:close(Db)
    end.

scan_dbs_fold(#full_doc_info{} = FDI, #st{shards_db = Db} = Acc) ->
    Acc1 = reset_scan_fields(Acc),
    Acc2 = Acc1#st{cursor = FDI#full_doc_info.id},
    Acc3 = maybe_checkpoint(Acc2),
    case couch_db:open_doc(Db, FDI, [ejson_body]) of
        {ok, #doc{id = <<"_design/", _/binary>>}} ->
            {ok, Acc3};
        {ok, #doc{id = DbName, body = Body}} ->
            scan_db(shards(DbName, Body), Acc2)
    end.

scan_db([], #st{} = St) ->
    {ok, St};
scan_db([_ | _] = Shards, #st{} = St) ->
    #st{cursor = DbName, mod = Mod, pst = PSt} = St,
    {Go, PSt1} = Mod:db(PSt, DbName),
    St1 = St#st{pst = PSt1},
    case Go of
        ok ->
            St2 = fold_ddocs(fun scan_ddocs_fold/2, St1),
            St3 = lists:foldl(fun scan_shards_fold/2, St2, Shards),
            {ok, St3};
        skip ->
            {ok, St1};
        stop ->
            {stop, St1}
    end.

scan_ddocs_fold({meta, _}, #st{} = Acc) ->
    {ok, Acc};
scan_ddocs_fold({row, RowProps}, #st{} = Acc) ->
    DDoc = couch_util:get_value(doc, RowProps),
    scan_ddoc(couch_doc:from_json_obj(DDoc), Acc);
scan_ddocs_fold(complete, #st{} = Acc) ->
    {ok, Acc};
scan_ddocs_fold({error, Error}, _Acc) ->
    exit({shutdown, {scan_ddocs_fold, Error}}).

scan_shards_fold(#shard{} = Shard, #st{} = St) ->
    #st{mod = Mod, pst = PSt} = St,
    St1 = maybe_checkpoint(St),
    {Go, PSt1} = Mod:shard(PSt, Shard),
    St2 = St1#st{pst = PSt1},
    case Go of
        ok -> scan_docs(St2, Shard);
        skip -> St2
    end.

scan_ddoc(#doc{} = DDoc, #st{} = St) ->
    #st{cursor = DbName, mod = Mod, pst = PSt, ddocs = DDocs} = St,
    {Go, PSt1} = Mod:ddoc(PSt, DbName, DDoc),
    St1 = St#st{pst = PSt1},
    case Go of
        ok -> {ok, St1#st{ddocs = [DDoc | DDocs]}};
        skip -> {ok, St1};
        stop -> {stop, St1}
    end.

scan_docs(#st{} = St, #shard{} = Shard) ->
    case couch_db:open_int(Shard#shard.name, [?ADMIN_CTX]) of
        {ok, Db} ->
            {ok, DocTotal} = couch_db:get_doc_count(Db),
            St1 = St#st{db = Db, doc_total = DocTotal, doc_index = 0},
            {ok, St2} = couch_db:fold_docs(Db, fun scan_docs_fold/2, St1, []),
            St2;
        {not_found, _} ->
            St
    end.

scan_docs_fold(#full_doc_info{id = Id} = FDI, #st{} = St) ->
    #st{
        db = Db,
        doc_total = Total,
        doc_index = Index,
        mod = Mod,
        pst = PSt
    } = St,
    {Go, PSt1} = Mod:doc_id(PSt, Id, Index, Total, Db),
    St1 = St#st{pst = PSt1, doc_index = Index + 1},
    case Go of
        ok -> scan_doc(FDI, St1);
        skip -> {ok, St1};
        stop -> {stop, St1}
    end.

scan_doc(#full_doc_info{} = FDI, #st{} = St) ->
    St1 = maybe_checkpoint(St),
    #st{db = Db, mod = Mod, pst = PSt, ddocs = DDocs} = St1,
    {ok, #doc{} = Doc} = couch_db:open_doc(Db, FDI, [ejson_body]),
    {Go, PSt1} = Mod:doc(PSt, Db, DDocs, Doc),
    case Go of
        ok -> {ok, St1#st{pst = PSt1}};
        stop -> {stop, St1#st{pst = PSt1}}
    end.

maybe_checkpoint(#st{checkpoint_tsec = LastCheckpointTSec} = St) ->
    receive
        stop ->
            checkpoint(St),
            exit({shutdown, stop})
    after 0 ->
        ok
    end,
    case tsec() - LastCheckpointTSec > ?CHECKPOINT_INTERVAL_SEC of
        true -> checkpoint(St);
        false -> St
    end.

checkpoint(#st{} = St) ->
    #st{id = Id, mod = Mod, pst = PSt, cursor = Cursor} = St,
    JsonPSt = checkpoint_callback(Mod, PSt),
    CheckpointSt = #{<<"cursor">> => Cursor, <<"pst">> => JsonPSt},
    ok = couch_scanner_checkpoint:write(Id, CheckpointSt),
    St#st{checkpoint_tsec = tsec()}.

init_from_checkpoint(#st{id = Id, mod = Mod} = St) ->
    case couch_scanner_checkpoint:read(Id) of
        #{<<"cursor">> := Cur, <<"pst">> := JsonPSt} ->
            PSt1 = start_callback(Mod, JsonPSt),
            St#st{pst = PSt1, cursor = Cur, checkpoint_tsec = tsec()};
        not_found ->
            PSt1 = start_callback(Mod, undefined),
            Cur = <<>>,
            ok = init_checkpoint(Id, Mod, Cur, PSt1),
            St#st{pst = PSt1, cursor = Cur, checkpoint_tsec = tsec()}
    end.

start_callback(Mod, CheckpointSt) when is_atom(Mod) ->
    case Mod:start(CheckpointSt) of
        {ok, PSt} -> PSt;
        {reschedule, TSec} -> exit({shutdown, {reschedule, TSec}})
    end.

stop_callback(#st{mod = Mod, pst = PSt}) ->
    case Mod:stop(PSt) of
        ok -> ok;
        {reschedule, TSec} -> exit({shutdown, {reschedule, TSec}})
    end.

init_checkpoint(Id, Mod, Cur, PSt1) ->
    JsonPSt = #{} = checkpoint_callback(Mod, PSt1),
    CptCtx = #{
        <<"cursor">> => Cur,
        <<"pst">> => JsonPSt
    },
    ok = couch_scanner_checkpoint:write(Id, CptCtx).

checkpoint_callback(Mod, PSt) ->
    {ok, #{} = JsonPSt} = Mod:checkpoint(PSt),
    ejson_map(JsonPSt).

plugin_mod(<<Plugin/binary>>) ->
    Mod = binary_to_atom(Plugin),
    case code:ensure_loaded(Mod) of
        {module, _} ->
            check_callbacks(Mod),
            Mod;
        {error, Error} ->
            error({?MODULE, {missing_plugin_module, Mod, Error}})
    end.

check_callbacks(Mod) when is_atom(Mod) ->
    Cbks = [
        {start, 1},
        {stop, 1},
        {checkpoint, 1},
        {db, 2},
        {ddoc, 3},
        {shard, 2},
        {doc_id, 5},
        {doc, 4}
    ],
    Fun = fun({F, A}) ->
        case erlang:function_exported(Mod, F, A) of
            true -> ok;
            false -> error({?MODULE, {undefined_plugin_fun, Mod, F, A}})
        end
    end,
    lists:foreach(Fun, Cbks).

tsec() ->
    erlang:system_time(second).

shards(DbName, {Props = [_ | _]}) ->
    Shards = lists:sort(mem3_util:build_shards(DbName, Props)),
    Fun = fun({R, SList}) ->
        case mem3_util:rotate_list({DbName, R}, SList) of
            [#shard{node = N} = S | _] when N =:= node() ->
                {true, S};
            [_ | _] ->
                false
        end
    end,
    lists:filtermap(Fun, shards_by_range(lists:sort(Shards))).

shards_by_range(Shards) ->
    Fun = fun(#shard{range = R} = S, Acc) -> orddict:append(R, S, Acc) end,
    Dict = lists:foldl(Fun, orddict:new(), Shards),
    orddict:to_list(Dict).

fold_ddocs(Fun, #st{cursor = DbName} = Acc) ->
    QArgs = #mrargs{
        include_docs = true,
        extra = [{namespace, <<"_design">>}]
    },
    {ok, Acc1} = fabric:all_docs(DbName, [?ADMIN_CTX], Fun, Acc, QArgs),
    Acc1.

ejson_map(Obj) ->
    jiffy:decode(jiffy:encode(Obj), [return_maps]).

reset_scan_fields(#st{} = St) ->
    St#st{
        db = undefined,
        doc_total = 0,
        doc_index = 0,
        ddocs = []
    }.
