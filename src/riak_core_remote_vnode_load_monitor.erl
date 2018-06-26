-module(riak_core_remote_vnode_load_monitor).

-behaviour(gen_server).

%% API
-export(
[
    start_link/1,
    reset/1,
    update_responsiveness_measurement/5,
    get_request_response_measurement_dict/1

]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {

    %% This is the partition index
    index,
    n_val_maximum,      % we use this value to determine when to drop the first n_val_2 data points for the average
    half_n_val_maximum, % when N reaches this value we begin calculations for the second half of the data points
    request_response_pairs % dictionary of dictionaries



}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(Index) ->
    Name = list_to_atom(integer_to_list(Index)),
    gen_server:start_link({local, Name}, ?MODULE, [Index], []).

reset(Idx) ->
    gen_server:cast(list_to_atom(integer_to_list(Idx)), reset).

update_responsiveness_measurement(request_response_pass, Code, Idx, StartTime, Endtime) ->
    gen_server:cast(list_to_atom(integer_to_list(Idx)), {update_passed, Code, StartTime, Endtime});
update_responsiveness_measurement(request_response_fail, Code, Idx, StartTime, Endtime) ->
    gen_server:cast(list_to_atom(integer_to_list(Idx)), {update_failed, Code, StartTime, Endtime}).

get_request_response_measurement_dict(Index) ->
    gen_server:call(list_to_atom(integer_to_list(Index)), get_request_response_measurement_dict).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Index]) ->
    NMax = app_helper:get_env(riak_core, responseiveness_n, 10000),
    HalfNMax2 = NMax div 2,
    State = #state{
        index = Index,
        n_val_maximum = NMax,
        half_n_val_maximum = HalfNMax2,
        request_response_pairs = dict:new()
    },
    {ok, State}.

handle_call(get_request_response_measurement_dict, _From, State) ->
    {reply, State#state.request_response_pairs, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(reset, State) ->
    NMax = app_helper:get_env(riak_core, responseiveness_n, 10000),
    HalfNMax2 = NMax div 2,
    ResetState = #state{
        index = State#state.index,
        n_val_maximum = NMax,
        half_n_val_maximum = HalfNMax2,
        request_response_pairs = dict:new()
    },
    {noreply, ResetState};





handle_cast({update_passed, Code, T0, T1}, State=#state{request_response_pairs = Dict}) ->
    Diff = timer:now_diff(T1, T0),
    case dict:find(Code, Dict) of
        error ->
            CodeDict0 = make_new_code_dictionary(),
            CodeDict1 = update_distributions(request_response_pass, CodeDict0, Diff, State, Code),
            {noreply, State#state{request_response_pairs = dict:store(Code, CodeDict1, Dict)}};
        {ok, CodeDict0} ->
            _ = maybe_blacklist_vnode(request_response_pass, Code, Diff, State),
            CodeDict1 = update_distributions(request_response_pass, CodeDict0, Diff, State, Code),
            {noreply, State#state{request_response_pairs = dict:store(Code, CodeDict1, Dict)}}
    end;

handle_cast({update_failed, Code, T0, T1}, State=#state{request_response_pairs = Dict}) ->
    Diff = timer:now_diff(T1, T0),
    case dict:find(Code, Dict) of
        error ->
            CodeDict0 = make_new_code_dictionary(),
            CodeDict1 = update_distributions(request_response_fail, CodeDict0, Diff, State, Code),
            {noreply, State#state{request_response_pairs = dict:store(Code, CodeDict1, Dict)}};
        {ok, CodeDict0} ->
            CodeDict1 = update_distributions(request_response_fail, CodeDict0, Diff, State, Code),
            {noreply, State#state{request_response_pairs = dict:store(Code, CodeDict1, Dict)}}
    end;


handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_new_code_dictionary() ->
    D = dict:new(),
    Avg = 0,
    Var = 0,
    Std = 0,
    N = 0,
    AvgCumFreq = 0,
    VarCumFreq = 0,
    Distribution = {Avg, Var, Std, N, AvgCumFreq, VarCumFreq},
    D1 = dict:store(d1, Distribution, D),
    D2 = dict:store(d2, Distribution, D1),
    D2.


maybe_blacklist_vnode(request_response_pass, _Code, _Diff, _Dict) ->
    % deviation = (diff - mean) / std
    % we will use this measurement and a set threshold to determine whether or not to forward on  the information
    % over to riak_core_apl_blacklist
    ok;
maybe_blacklist_vnode(request_response_fail, _Code, _Diff, _Dict) ->
    % the rules here will be slightly different as we will be saving different information
    ok.

move_distributions(Dict) ->
    {ok, Dis2} = dict:find(d2, Dict),
    Avg = 0,
    Var = 0,
    Std = 0,
    N = 0,
    AvgCumFreq = 0,
    VarCumFreq = 0,
    Distribution = {Avg, Var, Std, N, AvgCumFreq, VarCumFreq},
    D1 = dict:store(d1, Dis2, Dict),
    D2 = dict:store(d2, Distribution, D1),
    D2.



update_distributions(request_response_pass, Dict, Diff, #state{index = Index, n_val_maximum = Max, half_n_val_maximum = HalfMax}, Code) ->
    {ok, Dis1} = dict:find(d1, Dict),
    {_, _, _, N, _, _} = Dis1,
    case {N == Max, N < HalfMax} of
        {true, _} ->
            NewDict0 = move_distributions(Dict),
            calculate_new_distribution(request_response_pass, d1, NewDict0, Diff, Index, Code);
        {false, true} ->
            % only calculate distribtuion 1
            calculate_new_distribution(request_response_pass, d1, Dict, Diff, Index, Code);
        {false, false} ->
            % calculate both distributions
            NewDict0 = calculate_new_distribution(request_response_pass, d1, Dict, Diff, Index, Code),
            calculate_new_distribution(request_response_pass, d2, NewDict0, Diff, Index, Code)
    end;

update_distributions(request_response_fail, Dict, _Diff, _State, _Code) ->
    lager:info("request_response_fail"),
    Dict.



calculate_new_distribution(request_response_pass, Name, Dict, Diff, Index, Code) ->
    case dict:find(Name, Dict) of
        error ->
            lager:error("dictionary did not contain distribtuion data for responsiveness timings at Index: ~p", []),
            Dict;
        {ok, {_OldAvg, _OldVar, _OldStd, OldN, OldAvgCumFreq, OldVarCumFreq}} ->
            N = OldN +1,
            AvgCumFreq = OldAvgCumFreq + Diff,
            Avg = AvgCumFreq / N,
            VarCumFreq = OldVarCumFreq + math:pow((Diff - Avg), 2),
            Var = VarCumFreq / N,
            Std = math:sqrt(Var),
            Value = {Avg, Var, Std, N, AvgCumFreq, VarCumFreq},
            lager:info("Code: ~p Index: ~p, Distribution: ~p, New Distribtion: ~p", [Code, Index, Name, Value]),
            dict:store(Name, Value, Dict);
        {ok, WrongFormat} ->
            lager:error("Code: ~p, Distribtion: ~p, at index:~p has the wrong format: ~p", [Code, Name, Index, WrongFormat]),
            Dict
    end;

calculate_new_distribution(request_response_fail, _Name, Dict, _Diff, _Index, _Code) ->
    Dict.