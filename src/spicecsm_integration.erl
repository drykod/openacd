%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Module to integrate with SpiceCSM.  See the integration module for what
%% the base API is.
-module(spicecsm_integration).
-author(micahw).

-behaviour(gen_server).

-include("log.hrl").

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
	start/1,
	start_link/1,
	raw_request/2,
	state_dump/0,
	split_id/1,
	combine_id/2
]).

%% gen_server callbacks
-export([
	init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-record(state, {
	server :: string(),
	session :: string(),
	count = 1 :: pos_integer()
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

-define(API_PATH, "/api/spiceAPIServer/spiceAPIServer.php").

%%====================================================================
%% API
%%====================================================================

-type(option_key() :: 'server' | 'username' | 'password').
-type(option() :: [{option_key(), string()}]).
-type(option_list() :: [option()]).
%% @doc Start linked with given options.
-spec(start_link/1 :: (Options :: option_list()) -> {'ok', pid()}).
start_link(Options) ->
    gen_server:start_link({local, integration}, ?MODULE, Options, []).

%% @doc Start unlinked.
-spec(start/1 :: (Options :: option_list()) -> {'ok', pid()}).
start(Options) ->
	gen_server:start({local, integration}, ?MODULE, Options, []).

%% @doc Perform a direct request to the integtation.  This will, of course, fail
%% horribly if the integration server is not spicecsm_integration.  Don't encode
%% your json structs.
-spec(raw_request/2 :: (Apicall :: binary(), Params :: any()) -> any()).
raw_request(Apicall, Params) ->
	gen_server:call(integration, {raw_request, Apicall, Params}).

%% @doc Return the current state of the integration server.  May fail if the 
%% integration server is not spicecsm_integration.
-spec(state_dump/0 :: () -> #state{}).
state_dump() ->
	gen_server:call(integration, state_dump).

%% @doc Return `{Tenantid, Brandid}' when given a `ComboId'
-spec(split_id/1 :: (Comboid :: string()) -> {pos_integer(), pos_integer()}).
split_id(Comboid) ->
	Tenant = list_to_integer(string:substr(Comboid, 1, 4)),
	Brand = list_to_integer(string:substr(Comboid, 5, 4)),
	{Tenant, Brand}.

%% @doc Combine the `Tenantid' and `Brandid' to the 8 character `Comboid' used
%% for the general client id
-spec(combine_id/2 :: (Tenantid :: pos_integer(), Brandid :: pos_integer()) -> string()).
combine_id(Tenantid, Brandid) ->
	Prepadded = integer_to_list(Tenantid * 1000 + Brandid),
	string:right(Prepadded, 8, $0).

%% @doc Imports some data into the mnesia data to enable the spicecsm_integration
%% to start much more quickly.
-spec(import/1 :: (Options :: option_list()) -> 'ok' | {'ok', pid()}).
import(Options) ->
	Server = case proplists:get_value(server, Options) of
		undefined ->
			erlang:error({badarg, no_server});
		Else ->
			Else
	end,
	Username = list_to_binary(proplists:get_value(username, Options, "")),
	Password = list_to_binary(proplists:get_value(password, Options, "")),
	{ok, Sid} = connect(Server, Username, Password).
	
	
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%--------------------------------------------------------------------
init(Options) ->
	case proplists:get_value(server, Options) of
		undefined ->
			{stop, no_server};
		BaseServer ->
			Username = list_to_binary(proplists:get_value(username, Options, "")),
			Password = list_to_binary(proplists:get_value(password, Options, "")),
			case connect(BaseServer, Username, Password) of
				{ok, Sid} ->
					Server = lists:append([BaseServer, ?API_PATH]),
					{ok, #state{server = Server, count = 2, session = Sid}};
				{error, Err} ->
					?WARNING("integration failed:  ~p", [Err]),
					{stop, Err}
			end
	end.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(state_dump, _From, State) ->
	{reply, {ok, State}, State};
handle_call({agent_exists, Agent}, _From, State) when is_list(Agent) ->
	Login = list_to_binary(Agent),
	{ok, Count, Reply} = request(State, <<"agentExists">>, [Login]),
	case check_error(Reply) of
		{error, Message} ->
			?WARNING("Integration error'ed:  ~p", [Message]),
			{reply, {error, Message}, State#state{count = Count}};
		{ok, {struct, [{<<"msg">>, <<"no results">>}]}} ->
			{reply, false, State#state{count = Count}};
		{ok, [{struct, _Proplist}]} ->
			{reply, true, State#state{count = Count}}
	end;
handle_call({agent_auth, Agent, PlainPassword}, _From, State) when is_list(Agent), is_list(PlainPassword) ->
	Login = list_to_binary(Agent),
	Password = list_to_binary(util:bin_to_hexstr(erlang:md5(PlainPassword))),
	{ok, Count, Reply} = request(State, <<"agentAuth">>, [{struct, [{<<"login">>, Login}, {<<"password">>, Password}]}]),
	case check_error(Reply) of
		{error, Message} ->
			?WARNING("Integration error'ed:  ~p", [Message]),
			{reply, {error, Message}, State#state{count = Count}};
		{ok, {struct, [{<<"msg">>, <<"deny">>}]}} ->
			{reply, deny, State#state{count = Count}};
		{ok, [{struct, Proplist}]} ->
			Intsec = list_to_integer(binary_to_list(proplists:get_value(<<"securitylevelid">>, Proplist))),
			Intprof = list_to_integer(binary_to_list(proplists:get_value(<<"tierid">>, Proplist))),
			{Profile, Security} = case {Intsec, Intprof} of
				{Secid, 4} when Secid < 4 ->
					{"Default", supervisor};
				{Secid, TierID} ->
					P = case TierID of
						1 -> "Tier 1";
						2 -> "Tier 2";
						3 -> "Tier 3";
						4 -> "Supervisor"
					end,
					S = case Secid of
						4 -> admin;
						_Else -> agent
					end,
					{P, S}
			end,
			{reply, {ok, Profile, Security}, State#state{count = Count}}
	end;
handle_call({client_exists, id, Value}, From, State) ->
	case handle_call({get_client, id, Value}, From, State) of
		{reply, none, Newstate} ->
			{reply, false, Newstate};
		{reply, Tuple, Newstate} when element(1, Tuple) =:= ok ->
			{reply, true, Newstate};
		Else ->
			Else
	end;
handle_call({get_client, id, Value}, _From, State) ->
	{Tenant, Brand} = split_id(Value),
	Request = [{struct, [
		{<<"tenant">>, Tenant},
		{<<"brand">>, Brand}
	]}],
	{ok, Count, Reply} = request(State, <<"brandExists">>, Request),
	case check_error(Reply) of
		{error, Message} ->
			?WARNING("Integration error'ed:  ~p", [Message]),
			{reply, {error, Message}, State#state{count = Count}};
		{ok, {struct, [{<<"msg">>, Message}]}} ->
			?INFO("Real message for noexists client:  ~p", [Message]),
			{reply, none, State#state{count = Count}};
		{ok, {struct, Proplist}} ->
			Label = binary_to_list(proplists:get_value(<<"brandlabel">>, Proplist)),
			Res = {ok, Label, Tenant, Brand, []},		
			{reply, Res, State#state{count = Count}}
	end;
handle_call({raw_request, Apicall, Params}, _From, State) ->
	{ok, Count, Reply} = request(State, Apicall, Params),
	{reply, Reply, State#state{count = Count}};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

connect(BaseServer, Username, Password) ->
	Server = lists:append([BaseServer, ?API_PATH]),
	application:start(inets),
	{ok, Count, Submitbody} = build_request(<<"connect">>, [Username, Password], 1),
	{ok, {{_Version, 200, _Ok}, _Headers, Body}} = http:request(post, {Server, [], "application/x-www-form-urlencoded", Submitbody}, [], []),
	{struct, Results} = mochijson2:decode(Body),
	case proplists:get_value(<<"result">>, Results) of
		null ->
			?WARNING("auth failure starting integration.  ~p", [Results]),
			{error, {auth_fail, proplists:get_value(<<"error">>, Results, no_message)}};
		undefined ->
			{error, {auth_fail, no_results, Results}};
		{struct, Details} ->
			Sid = proplists:get_value(<<"session">>, Details),
			Access = proplists:get_value(<<"security_level">>, Details),
			case {Sid, Access} of
				{undefined, _} ->
					?WARNING("No sid was defined in the details.  ~p", [Details]),
					{error, {auth_fail, no_sid}};
				{_, Num} when Num < 4 ->
					{stop, {auth_fail, insufficient_access}};
				{_Otherwise, _Goodnumm} ->
					?INFO("Starting integration with server ~p as user ~p", [Server, Username]),
					{ok, Sid}
			end
	end.
	
build_request(Apicall, Params, Count) when is_binary(Apicall) ->
	Cleanparams = Params,
	Struct = {struct, [
		{<<"method">>, Apicall},
		{<<"params">>, Cleanparams},
		{<<"id">>, Count}
	]},
	Body = iolist_to_binary(lists:append(["request=", mochijson2:encode(Struct)])),
	{ok, Count + 1, Body}.
	
request(State, Apicall, Params) ->
	{ok, Count, Submitbody} = build_request(Apicall, lists:append(Params, [State#state.session]), State#state.count),
	{ok, {{_Version, 200, _Ok}, _Headers, Body}} = http:request(post, {State#state.server, [], "application/x-www-form-urlencoded", Submitbody}, [], []),
	?DEBUG("The body:  ~p", [Body]),
	{struct, Reply} = mochijson2:decode(Body),
	{ok, Count, Reply}.

check_error(Reply) ->
	case proplists:get_value(<<"error">>, Reply) of
		null ->
			{ok, proplists:get_value(<<"result">>, Reply)};
		Else ->
			{error, Else}
	end.
