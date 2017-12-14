-module(ra_log_file_props_SUITE).
-compile(export_all).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     {group, tests}
    ].

all_tests() ->
    [
     write,
     write_missing_entry,
     multi_write_missing_entry,
     write_overwrite_entry,
     write_index_starts_zero,
     append,
     append_missing_entry,
     append_overwrite_entry,
     append_index_starts_one,
     take,
     take_out_of_range,
     fetch,
     fetch_out_of_range,
     last_index_term,
     fetch_term,
     fetch_out_of_range_term,
     next_index_term,
     read_write_meta,
     sync_meta,
     last_written,
     last_written_with_wal,
     last_written_with_segment_writer
    ].

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    _ = application:load(ra),
    ok = application:set_env(ra, data_dir, ?config(priv_dir, Config)),
    ok = application:set_env(ra, segment_max_entries, 128),
    application:ensure_all_started(ra),
    Config.

end_per_suite(Config) ->
    application:stop(ra),
    Config.

init_per_testcase(TestCase, Config) ->
    PrivDir = ?config(priv_dir, Config),
    Dir = filename:join(PrivDir, TestCase),
    register(TestCase, self()),
    [{test_case, TestCase}, {wal_dir, Dir} | Config].

%%------------------
%% Generators
%%------------------

log_entries_gen(N) ->
    ?LET(Length, choose(N, 100),
         ?LET(Terms, term_sequence_gen(Length),
              [{Idx, Term, <<Idx:64/integer>>}
               || {Idx, Term} <- lists:zip(lists:seq(1, Length),
                                           Terms)])).

term_sequence_gen(N) ->
    ?LET(List, vector(N, non_neg_integer()),
         lists:sort(List)).

wait_sequence_gen(N) ->
    ?LET(List, vector(N, wait_gen()), List).

wait_gen() ->
    frequency([{5, 0}, {3, choose(1, 50)}, {1, choose(100, 500)}]).

consume_gen(N) ->
    ?LET(List, vector(N, boolean()), List).

log_entry_but_one_gen() ->
    ?LET(Idx, ?SUCHTHAT(Int, integer(), Int =/= 1),
         {Idx, 1, <<Idx:64/integer>>}).

log_entry_but_one_zero_gen() ->
    ?LET(Idx, ?SUCHTHAT(Int, integer(), (Int =/= 1) and (Int =/= 0)),
         {Idx, 1, <<Idx:64/integer>>}).

slice_gen(Entries) ->
    %% Head might be an empty list
    ?LET(N, choose(1, max_length(Entries)),
         begin
             {Head, [NEntry | Tail]} = lists:split(N - 1, Entries),
             {Head, NEntry, Tail}
         end).

sorted_subset_gen(Entries) ->
    ?LET(Subset, list(elements(Entries)), lists:sort(Subset)).

max_length(Entries) when length(Entries) > 1 ->
    length(Entries) - 1;
max_length(_) ->
    1.

range_gen(Entries) ->
    %% Range can finish anywhere after total number of entries
    ?LET(Start, between_gen(1, length(Entries)),
         ?LET(Num, greater_than_gen(1),
              {Start, Num})).

out_of_range_begin_gen() ->
    %% The range starts before the initial index
    ?LET(Start, less_than_gen(0),
         ?LET(Num, greater_than_gen(0),
              {Start, Num})).

out_of_range_end_gen(Entries) ->
    %% The range starts after the last index
    ?LET(Start, greater_than_gen(length(Entries)),
         ?LET(Num, non_neg_integer(),
              {Start, Num})).

between_gen(N, M) ->
    choose(N, M).

greater_than_gen(N) ->
    integer(N + 1, inf).

less_than_gen(N) ->
    integer(inf, N - 1).

out_of_range_gen(Entries) ->
    oneof([out_of_range_begin_gen(),
           out_of_range_end_gen(Entries)]).

%%------------------
%% Properties
%%------------------

write(Config) ->
    %% There is no way to create a log file from a list of entries without the write
    %% API. We have to prove first that writting a consecutive log file succeeds,
    %% so we can use it as a base for our tests
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun write_prop/2, [Dir, TestCase], 100).

write_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       begin
           {queued, Log0} = ra_log_file:write(
                             Entries,
                             ra_log_file:init(#{directory => Dir, id => TestCase})),
           {LogEntries, Log} = ra_log_file:take(1, length(Entries), Log0),
           reset(Log),
           ?WHENFAIL(io:format("Entries taken from the log: ~p~nRa log state: ~p~n",
                               [LogEntries, Log]),
                     Entries == LogEntries)
       end).

append_all([], Log) ->
    Log;
append_all([Entry | Entries], Log0) ->
    {queued, Log} = ra_log_file:append(Entry, Log0),
    append_all(Entries, Log).

write_missing_entry(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun write_missing_entry_prop/2, [Dir, TestCase], 100).

write_missing_entry_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(3),
       ?FORALL(
          {Head, _Entry, Tail}, slice_gen(Entries),
          begin
              Log = ra_log_file:init(#{directory => Dir, id => TestCase}),
              Reply = ra_log_file:write(Head ++ Tail, Log),
              reset(Log),
              ?WHENFAIL(io:format("Reply: ~p~n", [Reply]),
                        Reply == {error, integrity_error})
          end)).

write_overwrite_entry(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun write_overwrite_entry_prop/2, [Dir, TestCase], 100).

write_overwrite_entry_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(3),
       ?FORALL(
          {Head, {Idx, Term, _Value} = _Entry, _Tail}, slice_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              NewEntry = [{Idx, Term, <<"overwrite">>}],
              {queued, Log} = ra_log_file:write(NewEntry, Log0),
              {LogEntries, Log1} = ra_log_file:take(1, length(Entries), Log),
              reset(Log1),
              ?WHENFAIL(io:format("Head: ~p~n New entry: ~p~n"
                                  "Entries taken from the log: ~p~n"
                                  "Ra log state: ~p~n",
                                  [Head, NewEntry, LogEntries, Log1]),
                        ((Head ++ NewEntry) == LogEntries))
          end)).

multi_write_missing_entry(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun multi_write_missing_entry_prop/2, [Dir, TestCase], 100).

multi_write_missing_entry_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(3),
       ?FORALL(
          {Head, _Entry, Tail}, slice_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Head,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              Reply = ra_log_file:write(Tail, Log0),
              reset(Log0),
              ?WHENFAIL(io:format("Reply: ~p~n", [Reply]),
                        Reply == {error, integrity_error})
          end)).

append_missing_entry(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun append_missing_entry_prop/2, [Dir, TestCase], 100).

append_missing_entry_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(3),
       ?FORALL(
          {Head, _Entry, Tail}, slice_gen(Entries),
          begin
              Log0 = append_all(Head,
                               ra_log_file:init(#{directory => Dir, id => TestCase})),
              Failed = try
                           ra_log_file:append(hd(Tail), Log0),
                           false
                       catch
                           exit:integrity_error ->
                               true
                       end,
              {LogEntries, Log} = ra_log_file:take(1, length(Head), Log0),
              reset(Log),
              ?WHENFAIL(io:format("Failed: ~p~nHead: ~p~n Tail: ~p~n"
                                  "Entries taken from the log: ~p~n"
                                  "Ra log state: ~p~n",
                                  [Failed, Head, Tail, LogEntries, Log]),
                        (Head == LogEntries) and Failed)
          end)).

write_index_starts_zero(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun write_index_starts_zero_prop/2, [Dir, TestCase], 100).

write_index_starts_zero_prop(Dir, TestCase) ->
    ?FORALL(
       Entry, log_entry_but_one_zero_gen(),
       begin
           Log = ra_log_file:init(#{directory => Dir, id => TestCase}),
           Reply = ra_log_file:write([Entry], Log),
           reset(Log),
           ?WHENFAIL(io:format("Reply: ~p~n",
                               [Reply]),
                     Reply == {error, integrity_error})
       end).

append(Config) ->
    %% There is no way to create a log file from a list of entries without the write
    %% API. We have to prove first that writting a consecutive log file succeeds,
    %% so we can use it as a base for our tests
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun append_prop/2, [Dir, TestCase], 100).

append_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       begin
           Log0 = append_all(
                   Entries,
                   ra_log_file:init(#{directory => Dir, id => TestCase})),
           {LogEntries, Log} = ra_log_file:take(1, length(Entries), Log0),
           reset(Log),
           ?WHENFAIL(io:format("Entries taken from the log: ~p~nRa log state: ~p~n",
                               [LogEntries, Log]),
                     Entries == LogEntries)
       end).

append_overwrite_entry(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun append_overwrite_entry_prop/2, [Dir, TestCase], 100).

append_overwrite_entry_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(3),
       ?FORALL(
          {_Head, {Idx, Term, _Value} = _Entry, _Tail}, slice_gen(Entries),
          begin
              {queued, Log} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              Failed = try
                           ra_log_file:append({Idx, Term, <<"overwrite">>}, Log),
                           false
                       catch
                           exit:integrity_error ->
                               true
                       end,
              reset(Log),
              ?WHENFAIL(io:format("Failed: ~p~n", [Failed]),
                        Failed)
          end)).

append_index_starts_one(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun append_index_starts_one_prop/2, [Dir, TestCase], 100).

append_index_starts_one_prop(Dir, TestCase) ->
    ?FORALL(
       Entry, log_entry_but_one_gen(),
       begin
           Log = ra_log_file:init(#{directory => Dir, id => TestCase}),
           Failed = try
                       ra_log_file:append(Entry, Log),
                       false
                   catch
                       exit:integrity_error ->
                           true
                   end,
           reset(Log),
           ?WHENFAIL(io:format("Failed: ~p Entry: ~p~n", [Failed, Entry]), Failed)
       end).

take(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun take_prop/2, [Dir, TestCase], 100).

take_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {Start, Num}, range_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                 Entries,
                                 ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Selected, Log} = ra_log_file:take(Start, Num, Log0),
              Expected = lists:sublist(Entries, Start, Num),
              reset(Log),
              ?WHENFAIL(io:format("Selected: ~p~nExpected: ~p~n",
                                  [Selected, Expected]),
                        Selected == Expected)
          end)).

take_out_of_range(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun take_out_of_range_prop/2, [Dir, TestCase], 100).

take_out_of_range_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {Start, Num}, out_of_range_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Reply, Log} = ra_log_file:take(Start, Num, Log0),
              reset(Log),
              ?WHENFAIL(io:format("Start: ~p Num: ~p~nReply: ~p~n", [Start, Num, Reply]),
                        Reply == [])
          end)).

fetch(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun fetch_prop/2, [Dir, TestCase], 100).

fetch_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {_Head, {Idx, _Term, _Value} = Entry, _Tail}, slice_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Got, Log} = ra_log_file:fetch(Idx, Log0),
              reset(Log),
              ?WHENFAIL(io:format("Got: ~p Expected: ~p~n", [Got, Entry]),
                        Entry == Got)
          end)).

fetch_out_of_range(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun fetch_out_of_range_prop/2, [Dir, TestCase], 100).

fetch_out_of_range_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {Start, _Num}, out_of_range_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Reply, Log} = ra_log_file:fetch(Start, Log0),
              reset(Log),
              ?WHENFAIL(io:format("Got: ~p Expected: undefined~n", [Reply]),
                        Reply == undefined)
          end)).

last_index_term(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun last_index_term_prop/2, [Dir, TestCase], 100).

last_index_term_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(0),
       begin
           {queued, Log} = ra_log_file:write(
                             Entries,
                             ra_log_file:init(#{directory => Dir, id => TestCase})),
           {LastIdx, LastTerm} = case Entries of
                                     [] ->
                                         {0, 0};
                                     _ ->
                                         {LI, LT, _} = lists:last(Entries),
                                         {LI, LT}
                                 end,
           {Idx, Term} = ra_log_file:last_index_term(Log),
           reset(Log),
           ?WHENFAIL(io:format("Got: ~p Expected: ~p~n", [{Idx, Term}, {LastIdx, LastTerm}]),
                     (LastIdx == Idx) and (LastTerm == Term))
       end).

fetch_term(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun fetch_term_prop/2, [Dir, TestCase], 100).

fetch_term_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {_Head, {Idx, ExpectedTerm, _}, _Tail}, slice_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                Entries,
                                ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Term, Log} = ra_log_file:fetch_term(Idx, Log0),
              reset(Log),
              ?WHENFAIL(io:format("Got: ~p Expected: ~p~n", [Term, ExpectedTerm]),
                        (ExpectedTerm == Term))
          end)).

fetch_out_of_range_term(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun fetch_out_of_range_term_prop/2, [Dir, TestCase], 100).

fetch_out_of_range_term_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {Start, _}, out_of_range_gen(Entries),
          begin
              {queued, Log0} = ra_log_file:write(
                                 Entries,
                                 ra_log_file:init(#{directory => Dir, id => TestCase})),
              {Term, Log} = ra_log_file:fetch_term(Start, Log0),
              reset(Log),
              ?WHENFAIL(io:format("Got: ~p for index: ~p~n", [Term, Start]),
                        (undefined == Term) orelse ((0 == Term) and (Start == 0)))
          end)).

next_index_term(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun last_index_term_prop/2, [Dir, TestCase], 100).

next_index_term_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       begin
           {queued, Log} = ra_log_file:write(
                              Entries,
                              ra_log_file:init(#{directory => Dir, id => TestCase})),
           {LastIdx, _LastTerm, _} = lists:last(Entries),
           Idx = ra_log_file:next_index_term(Log),
           reset(Log),
           ?WHENFAIL(io:format("Got: ~p Expected: ~p~n", [Idx, LastIdx + 1]),
                     LastIdx + 1 == Idx)
       end).

read_write_meta(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun read_write_meta_prop/2, [Dir, TestCase], 100).

read_write_meta_prop(Dir, TestCase) ->
    ?FORALL(
       Meta0, list({atom(), binary()}),
       begin
           Log = write_meta(Meta0,
                            ra_log_file:init(#{directory => Dir, id => TestCase})),
           %% Ensure we overwrite the duplicates before checking the writes
           Meta = dict:to_list(dict:from_list(Meta0)),
           Result = [{K, V, ra_log_file:read_meta(K, Log)} || {K, V} <- Meta],
           reset(Log),
           ?WHENFAIL(io:format("Got: ~p~n", [Result]),
                     lists:all(fun({_K, V, Value}) ->
                                       V == Value
                               end, Result))
       end).

sync_meta(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun sync_meta_prop/2, [Dir, TestCase], 100).

sync_meta_prop(Dir, TestCase) ->
    ?FORALL(
       Meta0, list({atom(), binary()}),
       begin
           Log = write_meta(Meta0,
                            ra_log_file:init(#{directory => Dir, id => TestCase})),
           ok == ra_log_file:sync_meta(Log)
       end).

write_meta([], Log) ->
    Log;
write_meta([{Key, Value} | Rest], Log0) ->
    {ok, Log} = ra_log_file:write_meta(Key, Value, Log0),
    write_meta(Rest, Log).

last_written_with_wal(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun last_written_with_wal_prop/2, [Dir, TestCase], 25).

build_action_list(Entries, Actions) ->
    lists:flatten(lists:map(fun(Index) ->
                                    E = lists:nth(Index, Entries),
                                    A = lists:foldl(fun({A0, I}, Acc) when I == Index ->
                                                            [A0 | Acc];
                                                       (_, Acc) ->
                                                            Acc
                                                    end, [], Actions),
                                    [E | A]
                            end, lists:seq(1, length(Entries)))).

position(Entries) ->
    choose(1, length(Entries)).

last_written_with_wal_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          Actions, list(frequency([{5, {{wait, wait_gen()}, position(Entries)}},
                                   {3, {consume, position(Entries)}},
                                   {2, {roll_wal, position(Entries)}},
                                   {2, {stop_wal, position(Entries)}},
                                   {2, {start_wal, position(Entries)}}])),
          begin
              flush(),
              All = build_action_list(Entries, Actions),
              Log0 = ra_log_file:init(#{directory => Dir, id => TestCase}),
              {Log, Last, LastIdx, Status} =
                  lists:foldl(fun({wait, Wait}, Acc) ->
                                      timer:sleep(Wait),
                                      Acc;
                                 (consume, {Acc0, Last0, LastIdx, St}) ->
                                      {Acc1, Last1} = consume_events(Acc0, Last0),
                                      {Acc1, Last1, LastIdx, St};
                                 (roll_wal, {_, _, _, wal_down} = Acc) ->
                                      Acc;
                                 (roll_wal, Acc) ->
                                      ra_log_wal:force_roll_over(ra_log_wal),
                                      Acc;
                                 (stop_wal, {Acc0, Last0, LastIdx, wal_up}) ->
                                      ok = supervisor:terminate_child(ra_log_wal_sup, ra_log_wal),
                                      {Acc0, Last0, LastIdx, wal_down};
                                 (stop_wal, {_, _, _, wal_down} = Acc) ->
                                      Acc;
                                 (start_wal, {Acc0, Last0, LastIdx, wal_down}) ->
                                      supervisor:restart_child(ra_log_wal_sup, ra_log_wal),
                                      {Acc0, Last0, LastIdx, wal_up};
                                 (start_wal, {_, _, _, wal_up} = Acc) ->
                                      Acc;
                                 ({Idx, _, _} = Entry, {Acc0, _, LastIdx, _} = Acc) when Idx > LastIdx + 1 ->
                                      {error, integrity_error} = ra_log_file:write([Entry], Acc0),
                                      Acc;
                                 ({Idx, _, _} = Entry, {Acc0, _, _, wal_down} = Acc) ->
                                      {error, wal_down} = ra_log_file:write([Entry], Acc0),
                                      Acc;
                                 ({Idx, _, _} = Entry, {Acc0, Last0, _LastIdx, St}) ->
                                      {queued, Acc} = ra_log_file:write([Entry], Acc0),
                                      {Acc, Last0, Idx, St}
                              end, {Log0, {0, 0}, 0, wal_up}, All),
              Got = ra_log_file:last_written(Log),
              {Written, Log1} = ra_log_file:take(1, LastIdx, Log),
              reset(Log1),
              ?WHENFAIL(io:format("Got: ~p, Expected: ~p Written: ~p~n Actions: ~p~n",
                                  [Got, Last, Written, All]),
                        (Got ==  Last) and (Written == lists:sublist(Entries, 1, LastIdx)))
          end)).

last_written_with_segment_writer(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun last_written_with_segment_writer_prop/2, [Dir, TestCase], 25).

last_written_with_segment_writer_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          Actions, list(frequency([{5, {{wait, wait_gen()}, position(Entries)}},
                                   {3, {consume, position(Entries)}},
                                   {2, {stop_segment_writer, position(Entries)}},
                                   {2, {start_segment_writer, position(Entries)}}])),
          begin
              flush(),
              All = build_action_list(Entries, Actions),
              Log0 = ra_log_file:init(#{directory => Dir, id => TestCase}),
              {Log, Last, LastIdx, Status} =
                  lists:foldl(fun({wait, Wait}, Acc) ->
                                      timer:sleep(Wait),
                                      Acc;
                                 (consume, {Acc0, Last0, LastIdx, St}) ->
                                      {Acc1, Last1} = consume_events(Acc0, Last0),
                                      {Acc1, Last1, LastIdx, St};
                                 (stop_segment_writer, {Acc0, Last0, LastIdx, sw_up}) ->
                                      ok = supervisor:terminate_child(ra_log_file_sup, ra_log_file_segment_writer),
                                      {Acc0, Last0, LastIdx, sw_down};
                                 (stop_segment_writer, {_, _, _, sw_down} = Acc) ->
                                      Acc;
                                 (start_segment_writer, {Acc0, Last0, LastIdx, sw_down}) ->
                                      {ok, _} = supervisor:restart_child(ra_log_file_sup, ra_log_file_segment_writer),
                                      {Acc0, Last0, LastIdx, sw_up};
                                 (start_segment_writer, {_, _, _, sw_up} = Acc) ->
                                      Acc;
                                 ({Idx, _, _} = Entry, {Acc0, _, LastIdx, _} = Acc) when Idx > LastIdx + 1 ->
                                      {error, integrity_error} = ra_log_file:write([Entry], Acc0),
                                      Acc;
                                 ({Idx, _, _} = Entry, {Acc0, Last0, _LastIdx, St}) ->
                                      {queued, Acc} = ra_log_file:write([Entry], Acc0),
                                      {Acc, Last0, Idx, St}
                              end, {Log0, {0, 0}, 0, sw_up}, All),
              Got = ra_log_file:last_written(Log),
              {Written, Log1} = ra_log_file:take(1, LastIdx, Log),
              reset(Log1),
              ?WHENFAIL(io:format("Got: ~p, Expected: ~p Written: ~p~n Actions: ~p~n",
                                  [Got, Last, Written, All]),
                        (Got ==  Last) and (Written == lists:sublist(Entries, 1, LastIdx)))
          end)).

last_written(Config) ->
    Dir = ?config(wal_dir, Config),
    TestCase = ?config(test_case, Config),
    run_proper(fun last_written_prop/2, [Dir, TestCase], 25).

last_written_prop(Dir, TestCase) ->
    ?FORALL(
       Entries, log_entries_gen(1),
       ?FORALL(
          {Waits, Consumes}, {wait_sequence_gen(length(Entries)), consume_gen(length(Entries))},
          begin
              flush(),
              Actions = lists:zip3(Entries, Waits, Consumes),
              Log0 = ra_log_file:init(#{directory => Dir, id => TestCase}),
              {Log, Last} = lists:foldl(fun({Entry, Wait, Consume}, {Acc0, Last0}) ->
                                                {queued, Acc} = ra_log_file:write([Entry], Acc0),
                                                timer:sleep(Wait),
                                                case Consume of
                                                    true ->
                                                        consume_events(Acc, Last0);
                                                    false ->
                                                        {Acc, Last0}
                                                end
                                end, {Log0, {0, 0}}, Actions),
              Got = ra_log_file:last_written(Log),
              reset(Log),
              ?WHENFAIL(io:format("Got: ~p, Expected: ~p~n Actions: ~p~n",
                                  [Got, Last, Actions]),
                        Got ==  Last)
          end)).

flush() ->
    receive
        {ra_log_event, _} ->
            flush()
    after 100 ->
            ok
    end.

consume_events(Log0, Last) ->
    receive
        {ra_log_event, {written, {_, To, Term}} = Evt} ->
            Log = ra_log_file:handle_event(Evt, Log0),
            consume_events(Log, {To, Term})
    after 0 ->
            {Log0, Last}
    end.

last_idx_term([]) ->
    {0,0};
last_idx_term(List) ->
    {Idx, Term, _} = lists:last(lists:sort(List)),
    {Idx, Term}.

%% TODO refactor
run_proper(Fun, Args, NumTests) ->
    ?assertEqual(
       true,
       proper:counterexample(erlang:apply(Fun, Args),
			     [{numtests, NumTests},
			      {on_output, fun(".", _) -> ok; % don't print the '.'s on new lines
					     (F, A) -> ct:pal(?LOW_IMPORTANCE, F, A) end}])).

reset(Log) ->
    supervisor:restart_child(ra_log_wal_sup, ra_log_file_segment_writer),
    supervisor:restart_child(ra_log_wal_sup, ra_log_wal),
    ra_log_file:write([{0, 0, empty}], Log),
    receive
        {ra_log_event, {written, {_, 0, 0}}} ->
            ok
    end,
    ra_log_file:close(Log).
                          