-module(ra_machine_version_SUITE).

-compile(export_all).

-export([
         ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


all_tests() ->
    [
     server_with_higher_version_needs_quorum_to_be_elected,
     unversioned_machine_never_sees_machine_version_command,
     unversioned_can_change_to_versioned,
     server_upgrades_machine_state_on_noop_command,
     lower_version_does_not_apply_until_upgraded
     % snapshot_persists_machine_version
    ].


%% gnarly: for rabbit_fifo we need to capture the active module and version
%% at the index to be snapshotted. This means the release_cursor effect need to be
%% overloaded to support a {version(), module()} field as well

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_, Config) ->
    PrivDir = ?config(priv_dir, Config),
    {ok, _} = ra:start_in(PrivDir),
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ok = logger:set_primary_config(level, all),
    ra_server_sup_sup:remove_all(),
    ServerName1 = list_to_atom(atom_to_list(TestCase) ++ "1"),
    ServerName2 = list_to_atom(atom_to_list(TestCase) ++ "2"),
    ServerName3 = list_to_atom(atom_to_list(TestCase) ++ "3"),
    Cluster = [{ServerName1, node()},
               {ServerName2, node()},
               {ServerName3, node()}],
    [
     {modname, TestCase},
     {cluster, Cluster},
     {cluster_name, TestCase},
     {uid, atom_to_binary(TestCase, utf8)},
     {server_id, {TestCase, node()}},
     {uid2, atom_to_binary(ServerName2, utf8)},
     {server_id2, {ServerName2, node()}},
     {uid3, atom_to_binary(ServerName3, utf8)},
     {server_id3, {ServerName3, node()}}
     | Config].

end_per_testcase(_TestCase, Config) ->
    catch ra:delete_cluster(?config(cluster, Config)),
    meck:unload(),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================
server_with_higher_version_needs_quorum_to_be_elected(Config) ->
    ok = logger:set_primary_config(level, all),
    Mod = ?config(modname, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun (_) -> init_state end),
    meck:expect(Mod, version, fun () -> 1 end),
    meck:expect(Mod, which_module, fun (_) -> Mod end),
    meck:expect(Mod, apply, fun (_, _, S) -> {S, ok} end),
    Cluster = ?config(cluster, Config),
    ClusterName = ?config(cluster_name, Config),
    Leader = start_cluster(ClusterName, {module, Mod, #{}}, Cluster),
    Followers = lists:delete(Leader, Cluster),
    meck:expect(Mod, version, fun () ->
                                      Self = self(),
                                      case whereis(element(1, Leader)) of
                                          Self -> 2;
                                          _ -> 1
                                      end
                              end),
    ra:stop_server(Leader),
    ra:restart_server(Leader),
    %% assert Leader node has correct machine version
    {ok, _, Leader2} = ra:members(hd(Followers)),
    ?assertNotEqual(Leader, Leader2),

    [LastFollower] = lists:delete(Leader2, Followers),
    meck:expect(Mod, version, fun () ->
                                      New = [whereis(element(1, Leader)),
                                             whereis(element(1, Leader2))],
                                      case lists:member(self(), New) of
                                          true -> 2;
                                          _  -> 1
                                      end
                              end),
    ra:stop_server(Leader2),
    ra:restart_server(Leader2),
    %% this last leader must now be a version 2 not 1
    {ok, _, Leader3} = ra:members(Leader2),

    ?assertNotEqual(LastFollower, Leader3),
    ok.

unversioned_machine_never_sees_machine_version_command(Config) ->
    Mod = ?config(modname, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun (_) -> init_state end),
    meck:expect(Mod, apply, fun (_, dummy, S) ->
                                    {S, ok};
                                (_, {machine_version, _, _}, _) ->
                                    exit(unexpected_machine_version_command);
                                (_, Cmd, _) ->
                                    {Cmd, ok}
                            end),
    ClusterName = ?config(cluster_name, Config),
    ServerId = ?config(server_id, Config),
    _ = start_cluster(ClusterName, {module, Mod, #{}}, [ServerId]),
    % need to execute a command here to ensure the noop command has been fully
    % applied. The wal fsync could take a few ms causing the race
    {ok, ok, _} = ra:process_command(ServerId, dummy),
    %% assert state_v1
    {ok, {_, init_state}, _} = ra:leader_query(ServerId,
                                               fun (S) -> S end),
    ok = ra:stop_server(ServerId),
    %% increment version
    % meck:expect(Mod, version, fun () -> 2 end),
    ok = ra:restart_server(ServerId),
    {ok, ok, _} = ra:process_command(ServerId, dummy),

    {ok, {_, init_state}, _} = ra:leader_query(ServerId, fun ra_lib:id/1),
    ok.

unversioned_can_change_to_versioned(Config) ->
    Mod = ?config(modname, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun (_) -> init_state end),
    meck:expect(Mod, apply, fun (_, dummy, S) -> {S, ok} end),
    ClusterName = ?config(cluster_name, Config),
    ServerId = ?config(server_id, Config),
    _ = start_cluster(ClusterName, {module, Mod, #{}}, [ServerId]),
    % need to execute a command here to ensure the noop command has been fully
    % applied. The wal fsync could take a few ms causing the race
    {ok, ok, _} = ra:process_command(ServerId, dummy),
    %% assert state_v1
    {ok, {_, init_state}, _} = ra:leader_query(ServerId, fun (S) -> S end),
    ok = ra:stop_server(ServerId),
    meck:expect(Mod, version, fun () -> 1 end),
    meck:expect(Mod, which_module, fun (_) -> Mod end),
    meck:expect(Mod, apply, fun (_, dummy, S) ->
                                    {S, ok};
                                (_, {machine_version, 0, 1}, init_state) ->
                                    {state_v1, ok}
                            end),
    %% increment version
    ok = ra:restart_server(ServerId),
    {ok, ok, _} = ra:process_command(ServerId, dummy),

    {ok, {_, state_v1}, _} = ra:leader_query(ServerId, fun ra_lib:id/1),
    ok.

server_upgrades_machine_state_on_noop_command(Config) ->
    Mod = ?config(modname, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun (_) -> init_state end),
    meck:expect(Mod, version, fun () -> 1 end),
    meck:expect(Mod, which_module, fun (_) -> Mod end),
    meck:expect(Mod, apply, fun (_, dummy, S) ->
                                    {S, ok};
                                (_, {machine_version, 0, 1}, init_state) ->
                                    {state_v1, ok};
                                (_, {machine_version, 1, 2}, state_v1) ->
                                    {state_v2, ok}
                            end),
    ClusterName = ?config(cluster_name, Config),
    ServerId = ?config(server_id, Config),
    _ = start_cluster(ClusterName, {module, Mod, #{}}, [ServerId]),
    % need to execute a command here to ensure the noop command has been fully
    % applied. The wal fsync could take a few ms causing the race
    {ok, ok, _} = ra:process_command(ServerId, dummy),
    %% assert state_v1
    {ok, {_, state_v1}, _} = ra:leader_query(ServerId,
                                             fun (S) ->
                                                    ct:pal("leader_query ~w", [S]),
                                                   S
                                             end),
    ok = ra:stop_server(ServerId),
    %% increment version
    meck:expect(Mod, version, fun () -> 2 end),
    ok = ra:restart_server(ServerId),
    {ok, ok, _} = ra:process_command(ServerId, dummy),

    {ok, {_, state_v2}, _} = ra:leader_query(ServerId, fun ra_lib:id/1),
    ok.

lower_version_does_not_apply_until_upgraded(Config) ->
    ok = logger:set_primary_config(level, all),
    Mod = ?config(modname, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun (_) -> init_state end),
    meck:expect(Mod, version, fun () -> 1 end),
    meck:expect(Mod, which_module, fun (_) -> Mod end),
    meck:expect(Mod, apply, fun
                                (_, {machine_version, _, _}, S) ->
                                    %% retain state for machine versions
                                    {S, ok};
                                (_, C, _) ->
                                    %% any other command replaces the state
                                    {C, ok}
                            end),
    Cluster = ?config(cluster, Config),
    ClusterName = ?config(cluster_name, Config),
    %% 3 node cluster, upgrade the first two to the later version
    %% leaving on efolower on a lower version
    Leader = start_cluster(ClusterName, {module, Mod, #{}}, Cluster),
    Followers = lists:delete(Leader, Cluster),
    meck:expect(Mod, version, fun () ->
                                      Self = self(),
                                      case whereis(element(1, Leader)) of
                                          Self -> 2;
                                          _ -> 1
                                      end
                              end),
    ra:stop_server(Leader),
    ra:restart_server(Leader),
    {ok, _, Leader2} = ra:members(Leader),
    [LastFollower] = lists:delete(Leader2, Followers),
    meck:expect(Mod, version, fun () ->
                                      New = [whereis(element(1, Leader)),
                                             whereis(element(1, Leader2))],
                                      case lists:member(self(), New) of
                                          true -> 2;
                                          _  -> 1
                                      end
                              end),
    ra:stop_server(Leader2),
    ra:restart_server(Leader2),

    %% process a command that should be replicated to all servers but only
    %% applied to new machine version servers
    {ok, ok, _} = ra:process_command(Leader, dummy),
    %% a little sleep to make it more likely that replication is complete to
    %% all servers and not just a quorum
    timer:sleep(100),

    %% the updated servers should have the same state
    {ok, {{Idx, _}, dummy}, _} = ra:local_query(Leader, fun ra_lib:id/1),
    {ok, {{Idx, _}, dummy}, _} = ra:local_query(Leader2, fun ra_lib:id/1),
    %% the last follower with the lower machine version should not have
    %% applied the last command
    {ok, {{LFIdx, _}, init_state}, _} = ra:local_query(LastFollower, fun ra_lib:id/1),
    %% TODO: the follower should have received and persisted the entry
    %% and updated it's commit index but no its last_applied

    ?assert(Idx > LFIdx),
    ok.

snapshot_persists_machine_version(_Config) ->
    error({todo, ?FUNCTION_NAME}).

%% Utility

validate_state_enters(States) ->
    lists:foreach(fun (S) ->
                          receive {ra_event, _, {machine, {state_enter, S}}} -> ok
                          after 250 ->
                                    flush(),
                                    ct:pal("S ~w", [S]),
                                    exit({timeout, S})
                          end
                  end, States).

start_cluster(ClusterName, Machine, ServerIds) ->
    {ok, Started, _} = ra:start_cluster(ClusterName, Machine, ServerIds),
    {ok, _, Leader} = ra:members(hd(Started)),
    ?assertEqual(length(ServerIds), length(Started)),
    Leader.

validate_process_down(Name, 0) ->
    exit({process_not_down, Name});
validate_process_down(Name, Num) ->
    case whereis(Name) of
        undefined ->
            ok;
        _ ->
            timer:sleep(100),
            validate_process_down(Name, Num-1)
    end.

flush() ->
    receive
        Any ->
            ct:pal("flush ~p", [Any]),
            flush()
    after 0 ->
              ok
    end.
