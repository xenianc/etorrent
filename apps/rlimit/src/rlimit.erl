-module(rlimit).
%% This module implements an RED strategy layered on top of a token bucket
%% for shaping a message flow down to a user defined rate limit. Each message
%% must be assigned a symbolical size in tokens.
%%
%% The rate is measured and limited over short intervals, by default the
%% interval is set to one second.
%%
%% There is a total amount of tokens allowed to be sent or received by
%% the flow during each interval. As the the number of tokens approaches
%% that limit the probability of a message being delayed increases.
%%
%% When the amount of tokens has exceeded the limit all messages are delayed
%% until the start of the next interval.
%%
%% When the number of tokens needed for a message exceeds the number of tokens
%% allowed per interval the receiver or sender must accumulate tokens over
%% multiple intervals.

%% exported functions
-export([new/3, join/1, wait/2, take/2]).

%% private functions
-export([reset/1]).


%% @doc Create a new rate limited flow.
%% @end
-spec new(atom(), pos_integer() | infinity, non_neg_integer()) -> ok.
new(Name, Limit, Interval) ->
    ets:new(Name, [public, named_table, set]),
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, reset, [Name]),
    ets:insert(Name, [
        {version, 0},
        {limit, Limit},
        {fair, Limit},
        {tokens, Limit},
        {timer, TRef}]),
    ok.


%% @private Reset the token counter of a flow.
-spec reset(atom()) -> true.
reset(Name) ->
    %% The version number starts at 0 and restarts when it reaches 16#FFFF.
    %% The version number can be rolling because we only use it as a way to
    %% tell logical intervals apart.
    ets:update_counter(Name, version, {2,1,16#FFFF,0}),
    %% Add Limit number of tokens to the bucket at the start of each interval.
    Limit = ets:lookup_element(Name, limit, 2),
    %% @todo Cap the token counter to Limit multiple a number of intevals to
    %% protect us from huge bursts after idle intervals. Use 5 intervals as
    %% a reasonable default for now.
    Cap = Limit * 5,
    ets:update_counter(Name, tokens, {2,Limit,Cap,Cap}).


%% @doc Add the current process as the member of a flow.
%% The process is removed from the flow when it exists. Exiting is the only
%% way to remove a member of a flow.
%% @end
-spec join(atom()) -> ok.
join(_Name) ->
    ok.


%% @doc Wait until the start of the next interval.
%% @end
-spec wait(atom(), non_neg_integer()) -> non_neg_integer().
wait(Name, _Version) ->
    %% @todo Hopefully, the scheduler will provide enough of a delay.
    erlang:yield(),
    %% @todo Warn when NewVersion =:= Version
    ets:lookup_element(Name, version, 2).


%% @doc Aquire a slot to send or receive N tokens.
%% @end
-spec take(non_neg_integer(), atom()) -> ok.
take(N, Name) when is_integer(N), N >= 0, is_atom(Name) ->
    Limit = ets:lookup_element(Name, limit, 2),
    Version = ets:lookup_element(Name, version, 2),
    take(N, Name, Limit, Version).

take(_N, _Name, infinity, _Version) ->
    ok;
take(N, Name, Limit, Version) when N >= 0 ->
    case ets:update_counter(Name, tokens, {2,-N}) of
        %% Limit exceeded. Return all tokens and wait for next interval.
        Tokens when Tokens =< 0 ->
            ets:update_counter(Name, tokens, {2,N}),
            NewVersion = wait(Name, Version),
            take(N, Name, Limit, NewVersion);
        Tokens ->
            %% Use difference between the bottom of the bucket and the previous
            %% token count and the packet size to compute the probability of a
            %% message being delayed.
            %% This gives smaller control protocol messages a higher likelyness of
            %% receiving service, avoiding starvation from larger data protocol
            %% messages consuming the rate of entire intervals when a low rate
            %% is used.
            PreviousTokens = Tokens + N,
            case random:uniform(PreviousTokens) of
                %% Allow message if the random number falls within
                %% the range of tokens left in the bucket after take.
                Rand when Rand =< Tokens ->
                    ok;
                 %% Disallow message if the random number falls within
                 %% the range of the tokens taken from the bucket.
                 Rand when Rand > Tokens ->
                    ets:update_counter(Name, tokens, {2,N}),
                    NewVersion = wait(Name, Version),
                    take(N, Name, Limit, NewVersion)
            end
    end.
