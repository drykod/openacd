%% @doc Common functions for the web and tcp-json agent connections.
%% It is up to the connection to handle login and agent launching.  After
%% that, json should be sent into this module, as well as cast messages
%% the connection does not handle internally.
%%
%% == Json API ==
%%
%% The Json API as two sides, client requests and server events.  OpenACD's
%% policy is to assume the client connections are complete idiots, and
%% therefore not worth asking about anything; not event if an event has been
%% handled.  Thus, requests always come from the client, and events always
%% come from the server.
%%
%% === Requests ===
%%
%% A Json request will have the following form:
%% <pre>{"request_id":any(),
%% (optional)"module": module_name()(string()),
%% "function": function_name()(string()),
%% (optional)"args": any() | [any()]}</pre>
%%
%% If the module name is omitted, it is assumed to be this module
%% ({@module}); ie: handled intenrally.  If args is not an array, it is
%% wrapped in an array of length 1.  If args is omitted, it is assumed to
%% be an array of length 0.  This way, requests match up to erlang
%% Module:Function/Arity format.  Erlang functions in this module that have
%% {@agent_api} at the beginning of thier documentation conform to the form
%% above with one caveat:  The first argument is always the internal state
%% of the connection, and is obviously not sent with the json requests.
%% Thus, a properly documented project will be useful to agent connection
%% and agent client developers.
%%
%% Request_id is an opaque type sent by the client; it is sent back with
%% the reply to enable asynchronous requests.
%%
%% A json response will have 3 major forms.
%%
%% A very simple success:
%% <pre> {
%%  "request_id": any(),
%% 	"success":  true
%% }</pre>
%% A success with a result:
%% <pre> {
%%  "request_id": any(),
%% 	"success":  true,
%% 	"result":   any()
%% }</pre>
%% A failure:
%% <pre> {
%%  "request_id":  any(),
%% 	"success":  false,
%% 	"message":  string(),
%% 	"errcode":  string()
%% }</pre>
%%
%% === Events ===
%%
%% A server event is a json object with at least a "command" property.  If
%% the command references a specific agent channel, it will also have a
%% "channel_id" property.  All other properties are specific to the server
%% events.
%%
%% == Erlang API ==
%%
%% There are two sides to the erlang API, the connection facing side (such
%% as a web or tcp connection), and the api handler side, such as this
%% module or plugins handing agent requests.
%%
%% === Agent Connections ===
%%
%% After the login procedure, init/1 should be called, passing in the agent
%% record (prefereably after the connection is set).  If a reply of
%% `{ok, state()}' is returned, stash the state.  It will be used in the
%% encode_cast, and handle_json functions.
%%
%% Both encode_cast and handle_json have the same return types.
%% <dl>
%% <dt>`{ok, json(), state()}'</dt><dd>If json() is undefined, no json is
%% to be sent.  Otherwise the json should be encoded using
%% ejrpc2_json:encode/1 and sent over the wire.</dd>
%% <dt>`{exit, json(), state()}'</dt><dd>the connection should commit
%% hari-kari.  If json() is undefined, that's all that needs to happen,
%% otherwise json should be sent, then death.</dd>
%% </dl>
%%
%% === Api Handlers ===
%%
%% Modules intended to handle json calls can do so in two ways.  The first
%% is to register a hook to {@link cpx_hooks. agent_api_call}.  This hook
%% is triggered if the module and function with the appropriate arity is
%% not found using the method described below.  The valid return values are
%% the same as for the static functions.  The hook is triggered with the
%% arguments:
%% <ul>
%% <li>`Connection :: state()': internal state of connection</li>
%% <li>`Module :: atom()': Module that was in the json</li>
%% <li>`Function :: atom()': Function that was in the json</li>
%% <li>`Args :: [any()]': Arguments list in the json</li>
%% </ul>
%%
%% The alternative is more efficient, preventing a call to cpx_hooks,
%% though there is no custom information passed to the module.  The module
%% has an attribute `agent_api_functions', which is a list of tuples of
%% type `{FunctionAtom, Arity}'.  The arity must be one more than the
%% number of arguments sent with the json request; this is because the
%% state of the agent connection is sent as the first argument.
%%
%% An api handler function (either kind) should return one of the following:
%% <dl>
%% <dt>`ok'</dt><dd>A simple success json is returned</dd>
%% <dt>`{ok, json()}'</dt><dd>A json success is sent with the given json
%% set as the result</dd>
%% <dt>`{error, bin_string(), bin_string()}}'</dt><dd>An error is
%% returned</dd>
%% <dt> `exit'</dt><dd>The connection should exit, likely taking the agent
%% fsm with it.  A simple success is returned.</dd>
%% <dt>`{exit, json()}'</dt><dd>The connection should exit, likely taking
%% the agent with it.  A success is returned, with the json as the result.
%% </dd>
%% </dl>
%%
%% Plugins that want to send server events to agents should send one of the
%% two arbitrary command messages.
%% <ul>
%% <li>`{arbitrary_command, Command, Props}'</li>
%% <li>`{arbitrary_command, ChannelPidOrId, Command, Props}'</li>
%% </ul>
%%
%% In both cases, `Command' should be either an atom or binary string.
%% Props can be either a json object struct, or a property list that can
%% be put into a json object struct.
%%
%% `ChannelPidOrId' is the channel id either in its pid form, string form,
%% or binary string form.  In any form, if the channel does not exist, the
%% message is ignored.
%%
%% When the event is sent, the command property and channelid (if given)
%% properties are automatically pre-pended onto the json struct.  The
%% result is sent to the connection for encoding and being sent over the
%% wire:
%%
%% <pre>{"command": string(),
%% "channelid": string(),
%% "field1": any(),
%% "field2": any(),...
%% "fieldN": any()
%% }</pre>
%%
%% @TODO: Document the server events.

-module(cpx_agent_connection).

-include("agent.hrl").
-include("call.hrl").
-include("queue.hrl").
-include_lib("stdlib/include/qlc.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-import(cpx_json_util, [l2b/1, b2l/1]).

-define(json(Struct), ejrpc2_json:encode(Struct)).
-define(reply_err(Id, Message, Code), ?json({struct, [{request_id, Id},
	{success, false}, {message, Message}, {errcode, Code}]})).
-define(simple_success(Id), ?json({struct, [{request_id, Id},
	{success, true}]})).
-define(reply_success(Id, Struct), ?json({struct, [{request_id, Id},
	{success, true}, {result, Struct}]})).

-type state() :: cpx_conn_state:state().

%% public api
-export([
	login/2,
	start/1,
	init/1,
	encode_cast/2,
	handle_json/2,
	handle_json/3
]).
% -export([
% 	%% requests, exported for documentation happy.
% 	agent_transfer/3,
% 	end_wrapup/2,
% 	get_agent_profiles/1,
% 	get_avail_agents/1,
% 	% get_endpoint/2,
% 	get_queue_transfer_options/2,
% 	% TODO implement
% 	%load_media/1,
% 	logout/1,
% 	media_call/3,
% 	media_call/4,
% 	media_cast/3,
% 	media_cast/4,
% 	%media_hangup/2,
% 	%plugin_call/3,
% 	queue_transfer/4,
% 	%ring_test/1,
% 	% set_endpoint/3,
% 	set_release/2,
% 	set_state/3,
% 	set_state/4,
% 	get_queue_list/1,
% 	get_brand_list/1,
% 	get_release_opts/1
% ]).

%% Supervisor API
% -export([
% 	release_agent/3,
% 	get_acd_status/1,
% 	kick_agent/2,
% 	set_agent_profile/3
% ]).

%% An easier way to do a lookup for api functions.
-agent_api_functions([
	{agent_transfer, 3},
	{end_wrapup, 2},
	{get_agent_profiles, 1},
	{get_avail_agents, 1},
	{get_endpoint, 2},
	{get_queue_transfer_options, 2},
	{get_tabs_menu, 1},
	% TODO implement
	%{load_media, 1},
	{logout, 1},
	{media_call, 3},
	{media_call, 4},
	{media_cast, 3},
	{media_cast, 4},
	{queue_transfer, 4},
	{set_endpoint, 3},
	{set_release, 2},
	{set_state, 3},
	{set_state, 4},

	{get_queue_list, 1},
	{get_brand_list, 1},
	{get_release_opts, 1}
]).

-supervisor_api_functions([
	{release_agent, 3},
	{get_acd_status, 1},
	{kick_agent, 2},
	{set_agent_profile, 3}
]).

%% =======================================================================
%% Public api
%% =======================================================================


%% @doc Attempt a log-in and initialize the state if successful
-spec(login/2 :: (Username :: string(), Password :: string()) ->
	{ok, #agent{}, state()} | {error, deny} | {error, duplicate}).
login(Username, Password) ->
	case agent_auth:auth(Username, Password) of
		{ok, Auth} ->
			start_agent_with_auth(Auth);
		_ ->
			{error, deny}
	end.

%% @doc Start a given agent by login
-spec start/1 :: (Login::string()) ->
	{ok, #agent{}, state()} | {error, noagent}.
start(Login) ->
	case agent_auth:get_agent(Login) of
		{ok, Auth} ->
			start_agent_with_auth(Auth);
		_ ->
			{error, noagent}
	end.

%% @doc After the connection has been started, this should be called to
%% seed the state.
-spec(init/1 :: (Agent :: #agent{}) -> {'ok', state()}).
init(Agent) ->
	{ok, cpx_conn_state:new(Agent)}.

%% @doc When the connection gets a cast it cannot handle, this should be
%% called.  It will either return an error, or json to pump out to the
%% client.
-spec(encode_cast/2 :: (State :: state(), Cast :: any()) ->
	{'error', any(), state()} | {'ok', json(), state()} | {error, unhandled}).
encode_cast(State, Cast) ->
	case Cast of
		{agent, M} ->
			handle_cast(M, State);
		{cpx_monitor_event, M} ->
			handle_monitor_event(M, State);
		_ ->
			{error, unhandled}
	end.

handle_json(State, Bin) ->
	handle_json(State, Bin, []).

handle_json(State, Bin, Mods) ->
	Resp = case ejrpc2:handle_req([cpx_agent_rpc|Mods], Bin, [{preargs, [State]}]) of
		ok -> undefined;
		{ok, R} -> R
	end,

	E = receive
		{'$cpx_agent_rpc', exit} -> exit
		after 0 -> ok
	end,

	{E, Resp, State}.

%% Internal

start_agent_with_auth(Auth) ->
	#agent_auth{id=Id, login=Username, skills=Skills,
		security_level=Security, profile=Profile, endpoints=Endpoints} = Auth,
	Agent = #agent{id = Id, login = Username,
		skills = Skills, profile = Profile,
		security_level = Security},
	{_, APid} = agent_manager:start_agent(Agent),
	Agent0 = Agent#agent{source = APid},
	case agent:set_connection(APid, self()) of
		ok ->
			agent:set_endpoints(APid, Endpoints),
			{ok, St} = init(Agent0),
			{ok, Agent0, St};
		error ->
			{error, duplicate}
	end.

%% doc After unwrapping the binary that will hold json, and connection
%% should call this.
% -spec(handle_json/2 :: (State :: state(), Json :: json()) ->
% 	{'ok', json(), state()} | {'error', any(), state()} |
% 	{'exit', json(), state()}).
% handle_json(State, {struct, Json}) ->
% 	Agent = State#state.agent,
% 	SecurityLevel = Agent#agent.security_level,
% 	ThisModBin = list_to_binary(atom_to_list(?MODULE)),
% 	ModBin = proplists:get_value(<<"module">>, Json, ThisModBin),
% 	ReqId = proplists:get_value(<<"request_id">>, Json),
% 	ModRes = try binary_to_existing_atom(ModBin, utf8) of
% 		ModAtom ->
% 			{ok, ModAtom}
% 	catch
% 		error:badarg ->
% 			{error, bad_module}
% 	end,
% 	FuncBin = proplists:get_value(<<"function">>, Json, <<"undefined">>),
% 	FuncRes = try binary_to_existing_atom(FuncBin, utf8) of
% 		FuncAtom ->
% 			{ok, FuncAtom}
% 	catch
% 		error:badarg ->
% 			{error, bad_function}
% 	end,
% 	Args = case proplists:get_value(<<"args">>, Json, []) of
% 		ArgsList when is_list(ArgsList) -> ArgsList;
% 		Term -> [Term]
% 	end,
% 	case {ModRes, FuncRes} of
% 		{{error, bad_module}, _} ->
% 			{ok, ?reply_err(ReqId, <<"no such module">>, <<"MODULE_NOEXISTS">>), State};
% 		{_, {error, bad_function}} ->
% 			{ok, ?reply_err(ReqId, <<"no such function">>, <<"FUNCTION_NOEXISTS">>), State};
% 		{{ok, Mod}, {ok, Func}} ->
% 			Attrs = Mod:module_info(attributes),
% 			AgentApiFuncs = proplists:get_value(agent_api_functions, Attrs, []),
% 			SupApiFuncs = proplists:get_value(supervisor_api_functions, Attrs, []),
% 			Arity = length(Args) + 1,
% 			InAgentApi = lists:member({Func, Arity}, AgentApiFuncs),
% 			InSupApi = lists:member({Func, Arity}, SupApiFuncs),
% 			HasSupPriv = lists:member(SecurityLevel, [supervisor, admin]),
% 			case InAgentApi or (HasSupPriv and InSupApi) of
% 				false ->
% 					case cpx_hooks:trigger_hooks(agent_api_call, [State, Mod, Func, Args]) of
% 						{error, unhandled} ->
% 							{ok, ?reply_err(ReqId, <<"no such function">>, <<"FUNCTION_NOEXISTS">>), State};
% 						{ok, HookRes} ->
% 							case HookRes of
% 								'exit' ->
% 									{exit, ?simple_success(ReqId), State};
% 								{'exit', ResultJson} ->
% 									{exit, ?reply_success(ReqId, ResultJson), State};
% 								ok ->
% 									{ok, ?simple_success(ReqId), State};
% 								{ok, ResultJson} ->
% 									{ok, ?reply_success(ReqId, ResultJson), State};
% 								{error, Msg, Code} ->
% 									{ok, ?reply_err(ReqId, Msg, Code), State};
% 								Else ->
% 									ErrMsg = list_to_binary(io_lib:format("~p", [Else])),
% 									{ok, ?reply_err(ReqId, ErrMsg, <<"UNKNOWN_ERROR">>), State}
% 							end
% 					end;
% 				true ->
% 					try apply(Mod, Func, [State | Args]) of
% 						'exit' ->
% 							{exit, ?simple_success(ReqId), State};
% 						{'exit', ResultJson} ->
% 							{exit, ?reply_success(ReqId, ResultJson), State};
% 						ok ->
% 							{ok, ?simple_success(ReqId), State};
% 						{ok, ResultJson} ->
% 							{ok, ?reply_success(ReqId, ResultJson), State};
% 						{error, Msg, Code} ->
% 							{ok, ?reply_err(ReqId, Msg, Code), State};
% 						Else ->
% 							ErrMsg = list_to_binary(io_lib:format("~p", [Else])),
% 							{ok, ?reply_err(ReqId, ErrMsg, <<"UNKNOWN_ERROR">>), State}
% 					catch
% 						What:Why ->
% 							ErrMsg = list_to_binary(io_lib:format("error occured:  ~p:~p", [What, Why])),
% 							{ok, ?reply_err(ReqId, ErrMsg, <<"UNKNOWN_ERROR">>), State}
% 					end
% 			end
% 	end;

% handle_json(State, _InvalidJson) ->
% 	{error, invalid_json, State}.

%% =======================================================================
%% Agent connection api
%% =======================================================================

%% doc {@agent_api} Logs the agent out.  The result is a simple success.
% -spec(logout/1 :: (State :: state()) -> 'exit').
% logout(_State) ->
% 	exit.

% %% @doc {@agent_api} Sets the release mode of the agent.  To set an agent in
% %% a release mode, pass `<<"Default">>', `<<"default">>', or
% %% `<<"Id:Name:Bias">>' as the arguement.  Setting the agent idle is done
% %% by sending `<<"none">>' or `false'.
% -spec(set_release/2 :: (State :: state(), Release :: binary() | 'false') ->
% 	{'ok', json(), state()} | {error, any(), state()}).
% set_release(State, Release) ->
% 	RelData = case Release of
% 		<<"none">> ->
% 			none;
% 		false ->
% 			none;
% 		<<"default">> ->
% 			default;
% 		<<"Default">> ->
% 			default;
% 		Else ->
% 			[Id, Name, Bias] = util:string_split(binary_to_list(Else), ":"),
% 			{Id, Name, list_to_integer(Bias)}
% 	end,
% 	APid = cpx_conn_state:get(State, agent_pid) ,
% 	agent:set_release(APid, RelData).

%% doc {@agent_api} Set the agent channel `Channel' to the given
%% `Statename' with default state data.  No result property as it either
%% worked or didn't.  There will likely be an event as well to set the agent
%% state, so it is recommended that no actual change occur on the agent UI
%% side until that event is received.
% -spec(set_state/3 :: (State :: state(), Channel :: binary(),
% 	Statename :: binary()) -> {'ok', json(), state()}).
% set_state(State, Channel, Statename) ->
% 	ChannelName = binary_to_list(Channel),
% 	StateName = binary_to_list(Statename),
% 	case fetch_channel(ChannelName, State) of
% 		none ->
% 			{error, <<"Channel not found">>, <<"CHANNEL_NOEXISTS">>};
% 		{Chan, _ChanState} ->
% 			case agent_channel:set_state(Chan, agent_channel:list_to_state(StateName)) of
% 				ok -> ok;
% 				{error, invalid} ->
% 					{error, <<"Channel state change invalid">>, <<"INVALID_STATE_CHANGE">>}
% 			end
% 	end.

%% doc {@agent_api} Set the agent channel `Channel' to the given
%% `Statename' with the given `Statedata'.  No result property as it either %% worked or it didn't.  State data will vary based on state.  Furthermore,
%% in the case of success, an event is sent later by the agent fsm.  It is
%% recommended that no change to the UI occur until that event is received.
% -spec(set_state/4 :: (State :: state(), ChannelBin :: binary(),
% 	StateBin :: binary(), StateDataBin :: binary()) ->
% 	{'ok', json(), state()}).
% set_state(State, ChannelBin, StateBin, StateDataBin) ->
% 	Channel = binary_to_list(ChannelBin),
% 	Statename = binary_to_list(StateBin),
% 	Statedata = binary_to_list(StateDataBin),
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"Channel not found">>, <<"CHANNEL_NOEXISTS">>};
% 		{Chan, _ChanState} ->
% 			case agent_channel:set_state(Chan, agent_channel:list_to_state(Statename), Statedata) of
% 				ok ->
% 					ok;
% 				invalid ->
% 					{error, <<"Channel state change invalid">>, <<"INVALID_STATE_CHANGE">>}
% 			end
% 	end.

%% doc {@agent_api} End wrapup the agent channel 'Channel'.  This also
%% kills the channel, making it available for use again.  No result
%% property as it iether worked or didn't.  There will also be an event
%% later sent by the agent fsm.  It is recommended that no UI changes
%% occur until that event comes in.
% -spec(end_wrapup/2 :: (State :: state(), ChanBin :: binary())
% 	-> {'ok', json(), state()}).
% end_wrapup(State, ChanBin) ->
% 	Channel = binary_to_list(ChanBin),
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"Channel not found">>, <<"CHANNEL_NOEXISTS">>};
% 		{Chan, _ChanState} ->
% 			case agent_channel:end_wrapup(Chan) of
% 				ok -> ok;
% 				invalid ->
% 					{error, <<"Channel not stopped">>, <<"INVALID_STATE_CHANGE">>}
% 			end
% 	end.

%% doc {@agent_api} Get a list of the agents that are currently available.
%% Result is:
%% <pre>[{
%% 	"name":  string(),
%% 	"profile":  string(),
%% 	"state":  "idle" | "released"
%% }]</pre>
% -spec(get_avail_agents/1 :: (State :: state()) ->
% 	{'ok', json(), state()}).
% get_avail_agents(_State) ->
% 	Agents = [agent:dump_state(Pid)|| {_K, {Pid, _Id, _Time, _Skills}} <-
% 		agent_manager:list()],
% 	Noms = [{struct, [{<<"name">>, list_to_binary(Rec#agent.login)}, {<<"profile">>, list_to_binary(Rec#agent.profile)}]} || Rec <- Agents],
% 	{ok, Noms}.

%% doc {@agent_api} Get a list of the profiles that are in the system.
%% Result is:
%% <pre>[{
%% 	"name":  string(),
%% 	"order":  number()
%% }]</pre>
% -spec(get_agent_profiles/1 :: (State :: state()) ->
% 	{'ok', json(), state()}).
% get_agent_profiles(_State) ->
% 	Profiles = agent_auth:get_profiles(),
% 	Jsons = [
% 		{struct, [{<<"name">>, list_to_binary(Name)}, {<<"order">>, Order}]} ||
% 		#agent_profile{name = Name, order = Order} <- Profiles
% 	],
% 	{ok, Jsons}.

% %% @doc {@agent_api} Transfer the call on the given `Channel' to `Agent'
% %% login name.  No result is sent back as it's a simple success or failure.
% -spec(agent_transfer/3 :: (State :: state(), ChannelBin :: binary(),
% 	Agent :: binary()) -> {'ok', json(), state()}).
% agent_transfer(State, ChannelBin, AgentBin) ->
% 	Channel = binary_to_list(ChannelBin),
% 	Agent = binary_to_list(AgentBin),
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"Channel not found">>, <<"CHANNEL_NOEXISTS">>};
% 		{Chan, _ChanState} ->
% 			case agent_channel:agent_transfer(Chan, Agent) of
% 				ok -> ok;
% 				invalid ->
% 					{error, <<"Channel refused">>, <<"INVALID_STATE_CHANGE">>}
% 			end
% 	end.

% %% @doc {@agent_api} @see media_call/5
% -spec(media_call/3 :: (State :: state(), Channel :: binary(),
% 	Command :: binary()) -> {'ok', json(), state()}).
% media_call(State, Channel, Command) ->
% 	media_call(State, Channel, Command, []).

% %% @doc {@agent_api} Forward a request to the media associated with an
% %% oncall agent channel.  `Command' is the name of the request to make.
% %% `Args' is a list of arguments to be sent with the `Command'.  Check the
% %% documentation of the media modules to see what possible returns there
% %% are.
% -spec(media_call/4 :: (State :: state(), ChannelBin :: binary(),
% 	Command :: binary(), Args :: [any()]) -> {'ok', json(), state()}).
% media_call(State, Channel, Command, Args) ->
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"Channel doesn't exist">>, <<"CHANNEL_NOEXISTS">>};
% 		{_ChanPid, #channel_state{call = #call{source = CallPid}}} ->
% 			try gen_media:call(CallPid, {?MODULE, Command, Args}) of
% 				invalid ->
% 					lager:debug("media call returned invalid", []),
% 					{error, <<"invalid media call">>, <<"INVALID_MEDIA_CALL">>};
% 				Response ->
% 					{ok, Response}
% 			catch
% 				exit:{noproc, _} ->
% 					lager:debug("Media no longer exists.", []),
% 					{error, <<"media no longer exists">>, <<"MEDIA_NOEXISTS">>};
% 				What:Why ->
% 					lager:debug("Media exploded:  ~p:~p", [What,Why]),
% 					ErrBin = list_to_binary(io_lib:format("~p:~p", [What,Why])),
% 					{error, ErrBin, <<"UNKNOWN_ERROR">>}
% 			end
% 	end.

% %% @doc {@agent_api} @see media_cast/5
% -spec(media_cast/3 :: (State :: state(), Channel :: binary(),
% 	Command :: binary()) -> {'ok', json(), state()}).
% media_cast(State, Channel, Command) ->
% 	media_cast(State, Channel, Command, []).

% %% @doc {@agent_api} Forward a command to the media associated with an
% %% oncall agent channel.  `Command' is the name of the command to send.
% %% `Args' is a list of arguments to send with the `Command'.  There is no
% %% reply expected, so a simple success is always returned.
% -spec(media_cast/4 :: (State :: state(), Channel :: binary(),
% 	Command :: binary(), Args :: [any()]) -> {'ok', json(), state()}).
% media_cast(State, Channel, Command, Args) ->
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"Channel doesn't exist">>, <<"CHANNEL_NOEXISTS">>};
% 		{_ChanPid, #channel_state{call = #call{source = CallPid}}} ->
% 			gen_media:cast(CallPid, {?MODULE, Command, Args}),
% 			ok
% 	end.

% %% @doc {@agent_api} Get the fields and skills an agent can assign to a
% %% media before transfering it back into queue.  Result:
% %% <pre>{
% %% 	"curentVars":  [{
% %% 		string():  string()
% %%	}],
% %%	"prompts":  [{
% %% 		"name":  string(),
% %% 		"label":  string(),
% %% 		"regex":  regex_string()
% %% 	}],
% %% 	"skills":[
% %%		string() | {"atom":  string(),  "value":  string()}
% %% 	]
% %% }</pre>
% -spec(get_queue_transfer_options/2 :: (State :: state(),
% 	Channel :: binary()) -> {'ok', json(), state()}).
% get_queue_transfer_options(State, Channel) ->
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"no such channel">>, <<"CHANNEL_NOEXISTS">>};
% 		{_Chan, #channel_state{call = Call}} when is_record(Call, call) ->
% 			{ok, Setvars} = gen_media:get_url_getvars(Call#call.source),
% 			{ok, {Prompts, Skills}} = cpx:get_env(transferprompt, {[], []}),
% 			Varslist = [begin
% 				Newkey = case is_list(Key) of
% 					true ->
% 						list_to_binary(Key);
% 					_ ->
% 						Key
% 				end,
% 				Newval = case is_list(Val) of
% 					true ->
% 						list_to_binary(Val);
% 					_ ->
% 						Val
% 				end,
% 				{Newkey, Newval}
% 			end ||
% 			{Key, Val} <- Setvars],
% 			Encodedprompts = [{struct, [{<<"name">>, Name}, {<<"label">>, Label}, {<<"regex">>, Regex}]} || {Name, Label, Regex} <- Prompts],
% 			Encodedskills = cpx_web_management:encode_skills(Skills),
% 			Json = {struct, [
% 				{<<"currentVars">>, {struct, Varslist}},
% 				{<<"prompts">>, Encodedprompts},
% 				{<<"skills">>, Encodedskills}
% 			]},
% 			{ok, Json};
% 		_Else ->
% 			{error, <<"channel is not oncall">>, <<"INVALID_STATE_CHANGE">>}
% 	end.

% %% doc {@agent_api} Force the agent channgel to disconnect the media;
% %% usually through a brutal kill of the media pid.  Best used as an
% %% emergency escape hatch, and not under normal call flow.  No result set
% %% as it's merely success or failure.
% % -spec(media_hangup/2 :: (State :: state(), Channel :: binary()) ->
% % 	{'ok', json(), state()}).
% % media_hangup(State, Channel) ->
% % 	case fetch_channel(Channel, State) of
% % 		none ->
% % 			{error, <<"no such channel">>, <<"CHANNEL_NOEXISTS">>};
% % 		{_ChanPid, #channel_state{call = Call}} when is_record(Call, call) ->
% % 			lager:debug("The agent is committing call murder!", []),
% % 			exit(Call#call.source, agent_connection_request),
% % 			ok;
% % 		_ ->
% % 			{error, <<"channel not oncall">>, <<"INVALID_STATE_CHANGE">>}
% % 	end.

% %% @doc {@agent_api} Transfer the channel's call into `Queue' with
% %% the given `Opts'.  The options is a json object with any number of
% %% properties that are passed to the media.  If there is a property
% %% `"skills"' with a list, the list is interpreted as a set of skills to
% %% apply to the media.  No result is set as it is merely success or
% %% failure.
% -spec(queue_transfer/4 :: (State :: state(), QueueBin :: binary(),
% 	Channel :: binary(), Opts :: json()) -> {'ok', json(), state()}).
% queue_transfer(State, QueueBin, Channel, {struct, Opts}) ->
% 	Queue = binary_to_list(QueueBin),
% 	{Skills, Opts0} = case lists:key_take(<<"skills">>, 1, Opts) of
% 		false -> {[], Opts};
% 		{value, PostedSkills, Opts1} ->
% 			FixedSkills = skills_from_post(PostedSkills),
% 			{FixedSkills, Opts1}
% 	end,
% 	case fetch_channel(Channel, State) of
% 		none ->
% 			{error, <<"no such channel">>, <<"CHANNEL_NOEXISTS">>};
% 		{Chan, #channel_state{call = Call}} when is_record(Call, call) ->
% 			gen_media:set_url_getvars(Call#call.source, Opts0),
% 			gen_media:add_skills(Call#call.source, Skills),
% 			case agent_channel:queue_transfer(Chan, Queue) of
% 				ok -> ok;
% 				invalid ->
% 					{error, <<"agent channel rejected transfer">>, <<"INVALID_STATE_CHANGE">>}
% 			end;
% 		_ ->
% 			{error, <<"agent channel not oncall">>, <<"INVALID_STATE_CHANGE">>}
% 	end.

% skills_from_post(Skills) ->
% 	skills_from_post(Skills, []).

% skills_from_post([], Acc) ->
% 	cpx_web_management:parse_posted_skills(Acc);

% skills_from_post([{struct, Props} | Tail], Acc) ->
% 	Atom = binary_to_list(proplists:get_value(<<"atom">>, Props)),
% 	Expanded = binary_to_list(proplists:get_value(<<"expanded">>, Props)),
% 	SkillString = "{" ++ Atom ++ "," ++ Expanded ++ "}",
% 	Acc0 = [SkillString | Acc],
% 	skills_from_post(Tail, Acc0);

% skills_from_post([Atom | Tail], Acc) when is_binary(Atom) ->
% 	Acc0 = [binary_to_list(Atom) | Acc],
% 	skills_from_post(Tail, Acc0).

% %% @doc {@agent_api} Get the agent's endpoint data for a given module.
% -spec(get_endpoint/2 :: (State :: state(), TypeBin :: binary()) ->
% 	{'ok', json(), state()}).
% get_endpoint(State, TypeBin) ->
% 	case catch erlang:binary_to_existing_atom(TypeBin, utf8) of
% 		{'EXIT', {badarg, _}} ->
% 			{error, <<"invalid endpoint type">>, <<"INVALID_ENDPOINT_TYPE">>};
% 		Type ->
% 			case agent:get_endpoint(Type, Agent) of
% 				{error, notfound} ->
% 					{ok, null};
% 				{ok, {InitOpts, _}} ->
% 					Json = endpoint_to_struct(Type, InitOpts),
% 					{ok, Json}
% 			end
% 	end.

% endpoint_to_struct(freeswitch_media, Data) ->
% 	FwType = proplists:get_value(type, Data, null), %% atom()
% 	FwData = case proplists:get_value(data, Data) of
% 		undefined -> null;
% 		Dat -> list_to_binary(Dat)
% 	end,
% 	Persistant = proplists:get_value(persistant, Data),
% 	{struct, [{type, FwType}, {data, FwData}, {persistant, Persistant}]};

% endpoint_to_struct(email_media, _Data) ->
% 	{struct, []};

% endpoint_to_struct(dummy_media, Opt) ->
% 	{struct, [{endpoint, Opt}]}.

%% doc {@agent_api} Sets the agent's endpoint data to the given, well, data.
%% Particularly useful if the flash phone is used, as all of the connection
%% data will not be available for that until it is started on in the
%% browser.
% TODO make this not media specific.
% -spec(set_endpoint/3 :: (State :: state(), Endpoint :: binary(),
% 	Data :: binary()) -> any()).
% set_endpoint(State, <<"freeswitch_media">>, Struct) ->
% 	set_endpoint_int(State, freeswitch_media, Struct, fun(Data) ->
% 		FwType = case proplists:get_value(<<"type">>, Data) of
% 			%<<"rtmp">> -> rtmp;
% 			<<"sip_registration">> -> sip_registration;
% 			<<"sip">> -> sip;
% 			<<"iax">> -> iax;
% 			<<"h323">> -> h323;
% 			<<"pstn">> -> pstn;
% 			_ -> undefined
% 		end,

% 		case FwType of
% 			undefined ->
% 				{error, unknown_fw_type};
% 			_ ->
% 				FwData = binary_to_list(proplists:get_value(<<"data">>,
% 					Data, <<>>)),
% 				Persistant = case proplists:get_value(<<"persistant">>,
% 					Data) of
% 						true -> true;
% 						_ -> undefined
% 				end,

% 				[{type, FwType}, {data, FwData}, {persistant, Persistant}]
% 		end
% 	end);

% set_endpoint(State, <<"email_media">>, _Struct) ->
% 	set_endpoint_int(State, email_media, {struct, []}, fun(_) -> ok end);

% set_endpoint(State, <<"dummy_media">>, Struct) ->
% 	set_endpoint_int(State, dummy_media, Struct, fun(Data) ->
% 		case proplists:get_value(<<"dummyMediaEndpoint">>, Data) of
% 			<<"ring_channel">> ->  ring_channel;
% 			<<"inband">> -> inband;
% 			<<"outband">> -> outband;
% 			<<"persistant">> -> persistant;
% 			_ -> {error, unknown_dummy_endpoint}
% 		end
% 	end);

% set_endpoint(_State, _Type, _Struct) ->
% 	{error, <<"unknwon endpoint">>, <<"INVALID_ENDPOINT">>}.

% set_endpoint_int(State, Type, {struct, Data}, DataToOptsFun) ->
% 	case DataToOptsFun(Data) of
% 		{error, Error} ->
% 			{error, iolist_to_binary(io_lib:format("error with input: ~p", [Error])), <<"INVALID_ENDPOINT">>};
% 		Opts ->
% 			#state{agent = Agent} = State,
% 			case agent:set_endpoint(Agent#agent.source, Type, Opts) of
% 				ok -> ok;
% 				{error, Error2} ->
% 					{error, iolist_to_binary(io_lib:format("error setting endpoint: ~p", [Error2])), <<"INVALID_ENDPOINT">>}
% 			end
% 	end.


%% doc Useful when a plugin needs to send information or results to the
%% agent ui.
% TODO another special snowflake.
% -spec(arbitrary_command/3 :: (Conn :: pid(), Command :: binary() | atom(),
% 	JsonProps :: [{binary() | atom(), any()}]) -> 'ok').
% arbitrary_command(Conn, Command, JsonProps) ->
% 	gen_server:cast(Conn, {arbitrary_command, Command, JsonProps}).

% %% @doc {@web} Returns a list of queues configured in the system.  Useful
% %% if you want agents to be able to place media into a queue.
% %% Result:
% %% `[{
% %% 	"name": string()
% %% }]'
% -spec(get_queue_list/1 :: (State :: state()) -> {ok, json()}).
% get_queue_list(_State) ->
% 	Queues = call_queue_config:get_queues(),
% 	QueuesEncoded = [{struct, [
% 		{<<"name">>, list_to_binary(Q#call_queue.name)}
% 	]} || Q <- Queues],
% 	{ok, QueuesEncoded}.

% %% @doc {@web} Returns a list of clients confured in the system.  Useful
% %% to allow agents to make outbound media.
% %% Result:
% %% `[{
% %% 	"label":  string(),
% %% 	"id":     string()
% %% }]'
% -spec(get_brand_list/1 :: (State :: state()) -> {ok, json()}).
% get_brand_list(_State) ->
% 	Brands = call_queue_config:get_clients(),
% 	BrandsEncoded = [{struct, [
% 		{<<"label">>, list_to_binary(C#client.label)},
% 		{<<"id">>, list_to_binary(C#client.id)}
% 	]} || C <- Brands, C#client.label =/= undefined],
% 	{ok, BrandsEncoded}.

% %% @doc {@web} Returns a list of options for use when an agents wants to
% %% go released.
% %% Result:
% %% `[{
% %% 	"label":  string(),
% %% 	"id":     string(),
% %% 	"bias":   -1 | 0 | 1
% %% }]'
% -spec(get_release_opts/1 :: (State :: state()) -> {ok, json()}).
% get_release_opts(_State) ->
% 	Opts = agent_auth:get_releases(),
% 	Encoded = [{struct, [
% 		{<<"label">>, list_to_binary(R#release_opt.label)},
% 		{<<"id">>, R#release_opt.id},
% 		{<<"bias">>, R#release_opt.bias}
% 	]} || R <- Opts],
% 	{ok, Encoded}.

% %% =======================================================================
% %% Supervisor APIs
% %% =======================================================================

% -spec kick_agent/2 :: (state(), Agent :: binary()) -> ok | {error, binary(), binary()}.
% kick_agent(_State, Agent) ->
% 	case agent_manager:query_agent(binary_to_list(Agent)) of
% 		{true, Apid} ->
% 			agent:stop(Apid),
% 			ok;
% 		false ->
% 			{error, <<"AGENT_NOEXISTS">>, <<"no such agent">>}
% 	end.

% -spec set_agent_profile/3 :: (state(), Agent :: binary(), Profile :: binary())
% 	-> ok | {error, binary(), binary()}.
% set_agent_profile(_State, Agent, Profile) ->
% 	Login = binary_to_list(Agent),
% 	Newprof = binary_to_list(Profile),
% 	case agent_manager:query_agent(Login) of
% 		{true, Apid} ->
% 			case agent:change_profile(Apid, Newprof) of
% 				ok ->
% 					ok;
% 				{error, unknown_profile} ->
% 					{error, <<"PROFILE_NOEXISTS">>, <<"unknown profile">>}
% 			end;
% 		false ->
% 			{error, <<"AGENT_NOEXISTS">>, <<"unknown agent">>}
% 	end.

% -spec release_agent/3 :: (state(), Agent :: binary(), Release :: binary())
% 	-> {ok, json()}.
% release_agent(_State, Agent, Release) ->
% 	case agent_manager:query_agent(binary_to_list(Agent)) of
% 		{true, Apid} ->
% 			RelOptKey = case Release of
% 				<<"default">> ->
% 					default;
% 				<<"none">> ->
% 					none;
% 				_ ->
% 					Release
% 			end,
% 			case agent:set_release(Apid, RelOptKey) of
% 				invalid ->
% 					{error, <<"INVALID_STATE_CHANGE">>, <<"invalid state change">>};
% 				ok ->
% 					ok;
% 				queued ->
% 					ok
% 			end;
% 		_Else ->
% 			{error, <<"AGENT_NOEXISTS">>, <<"Agent not found">>}
% 	end.

% get_acd_status(_State) ->
% 	% nodes, agents, queues, media, and system.
% 	cpx_monitor:subscribe(),
% 	Nodestats = qlc:e(qlc:q([X || {{node, _}, _, _, _, _, _} = X <- ets:table(cpx_monitor)])),
% 	Agentstats = qlc:e(qlc:q([X || {{agent, _}, _, _, _, _, _} = X <- ets:table(cpx_monitor)])),
% 	Queuestats = qlc:e(qlc:q([X || {{queue, _}, _, _, _, _, _} = X <- ets:table(cpx_monitor)])),
% 	Systemstats = qlc:e(qlc:q([X || {{system, _}, _, _, _, _, _} = X <- ets:table(cpx_monitor)])),
% 	Mediastats = qlc:e(qlc:q([X || {{media, _}, _, _, _, _, _} = X <- ets:table(cpx_monitor)])),
% 	Groupstats = extract_groups(lists:append(Queuestats, Agentstats)),
% 	Stats = lists:append([Nodestats, Agentstats, Queuestats, Systemstats, Mediastats]),
% 	{Count, Encodedstats} = encode_stats(Stats),
% 	{_Count2, Encodedgroups} = encode_groups(Groupstats, Count),
% 	Encoded = lists:append(Encodedstats, Encodedgroups),
% 	Systemjson = {struct, [
% 		{<<"id">>, <<"system-System">>},
% 		{<<"type">>, <<"system">>},
% 		{<<"display">>, <<"System">>},
% 		{<<"details">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, {struct, []}}]}}
% 	]},
% 	Result = {struct, [
% 		{<<"identifier">>, <<"id">>},
% 		{<<"label">>, <<"display">>},
% 		{<<"items">>, [Systemjson | Encoded]}
% 	]},
% 	{ok, Result}.

%% =======================================================================
%% Internal Functions
%% =======================================================================


%% -----------------------------------------------------------------------

%% -----------------------------------------------------------------------

handle_cast({arbitrary_command, Command, {struct, Props}}, State) ->
	handle_cast({arbitrary_command, Command, Props}, State);

handle_cast({arbitrary_command, Command, Props}, State) when is_atom(Command); is_binary(Command) ->
	Json = {struct, [{<<"command">>, Command} | Props]},
	{ok, Json, State};

handle_cast({arbitrary_command, Channel, Command, {struct, Props}}, State) ->
	handle_cast({arbitrary_command, Channel, Command, Props}, State);

handle_cast({arbitrary_command, ChanPid, Command, Props}, State) when is_binary(Command); is_atom(Command) ->
	case cpx_conn_state:get_id_by_channel_pid(State, ChanPid) of
		none ->
			{ok, undefined, State};
		ChanId ->
			Props0 = [{<<"command">>, Command}, {<<"channelid">>, ChanId} | Props],
			{ok, {struct, Props0}, State}
	end;
handle_cast({mediapush, ChanPid, Call, Data}, State) ->
	{_, State1} = cpx_conn_state:store_channel(State, ChanPid),
	case Data of
		% because freeswitch, legacy format
		EventName when is_atom(EventName) ->
			Props = [{<<"event">>, EventName}, {<<"media">>, Call#call.type}],
			handle_cast({arbitrary_command, ChanPid, <<"mediaevent">>, Props}, State1);
		% email uses this
		{mediaload, Call} ->
			Props = [{<<"media">>, Call#call.source_module}],
			handle_cast({arbitrary_command, ChanPid, <<"mediaload">>, Props}, State1);
		% freeswitch uses this
		{mediaload, Call, _Data} ->
			Props = [{<<"media">>, Call#call.source_module}],
			handle_cast({arbitrary_command, ChanPid, <<"mediaload">>, Props}, State1);
		% not sure what uses this.  It's still pretty messy.
		{Command, Call, EventData} ->
			Props = [{<<"event">>, EventData}, {<<"media">>, Call#call.type}],
			handle_cast({arbitrary_command, ChanPid, Command, Props}, State1);
		% one of two versions I'd like to see in the future
		{struct, Props} when is_list(Props) ->
			handle_cast({arbitrary_command, ChanPid, <<"mediaevent">>, Props}, State1);
		% and the second of the prefered versions
		Props when is_list(Props) ->
			handle_cast({arbitrary_command, ChanPid, <<"mediaevent">>, Props}, State1)
	end;

handle_cast({set_release, Release, Time}, State) ->
	ReleaseData = case Release of
		none ->
			false;
		{Id, Label, Bias} ->
			{struct, [
				{<<"id">>, list_to_binary(Id)},
				{<<"label">>, if is_atom(Label) -> Label; true -> list_to_binary(Label) end},
				{<<"bias">>, Bias}
			]}
	end,
	Json = {struct, [
		{<<"command">>, <<"arelease">>},
		{<<"releaseData">>, ReleaseData},
		{<<"changeTime">>, Time * 1000}
	]},
	{ok, Json, State};

handle_cast({set_channel, Pid, ChanState, Call}, State) ->
	{ChanId, State1} = cpx_conn_state:store_channel(State, Pid),
	Headjson = {struct, [
		{<<"command">>, <<"setchannel">>},
		{<<"state">>, ChanState},
		{<<"statedata">>, encode_call(Call)},
		{<<"channelid">>, ChanId}
	]},
	{ok, Headjson, State1};

handle_cast({channel_died, Pid, NewAvail}, State) ->
	{ChanId, State1} = cpx_conn_state:remove_channel(State, Pid),
	Resp = case ChanId of
		none ->
			undefined;
		_ ->
			{struct, [
				{<<"command">>, <<"endchannel">>},
				{<<"channelid">>, ChanId},
				{<<"availableChannels">>, NewAvail}]}
	end,
	{ok, Resp, State1};

handle_cast({change_profile, Profile}, State) ->
	Headjson = {struct, [
		{<<"command">>, <<"aprofile">>},
		{<<"profile">>, list_to_binary(Profile)}
	]},
	{ok, Headjson, State};

handle_cast({url_pop, URL, Name}, State) ->
	Headjson = {struct, [
		{<<"command">>, <<"urlpop">>},
		{<<"url">>, list_to_binary(URL)},
		{<<"name">>, list_to_binary(Name)}
	]},
	{ok, Headjson, State};

handle_cast({blab, Text}, State) when is_list(Text) ->
	handle_cast({blab, list_to_binary(Text)}, State);

handle_cast({blab, Text}, State) when is_binary(Text) ->
	Headjson = {struct, [
		{<<"command">>, <<"blab">>},
		{<<"text">>, Text}
	]},
	{ok, Headjson, State};

handle_cast({new_endpoint, _Module, _Endpoint}, State) ->
	%% TODO should likely actually tell the agent.  Maybe.
	{ok, undefined, State};

handle_cast({stop, _Reason, Msg}, State) when is_atom(Msg) ->
	Headjson = {struct, [
		{<<"event">>, <<"stop">>},
		{<<"message">>, atom_to_binary(Msg, utf8)}
	]},
	{exit, Headjson, State};

handle_cast(_E, State) ->
	{ok, undefined, State}.

handle_monitor_event({info, _, _}, State) ->
	% TODO fix the subscribe, or start using this.
	{ok, undefined, State};
handle_monitor_event(Message, State) ->
	%lager:debug("Ingesting cpx_monitor_event ~p", [Message]),
	Json = case Message of
		{drop, _Timestamp, {Type, Name}} ->
			Fixedname = if
				is_atom(Name) ->
					 atom_to_binary(Name, latin1);
				 true ->
					 list_to_binary(Name)
			end,
			{struct, [
				{<<"command">>, <<"supervisorDrop">>},
				{<<"data">>, {struct, [
					{<<"type">>, Type},
					{<<"id">>, list_to_binary([atom_to_binary(Type, latin1), $-, Fixedname])},
					{<<"name">>, Fixedname}
				]}}
			]};
		{set, _Timestamp, {{Type, Name}, Detailprop, _Node}} ->
			Encodeddetail = encode_proplist(Detailprop),
			Fixedname = if
				is_atom(Name) ->
					 atom_to_binary(Name, latin1);
				 true ->
					 list_to_binary(Name)
			end,
			{struct, [
				{<<"command">>, <<"supervisorSet">>},
				{<<"data">>, {struct, [
					{<<"id">>, list_to_binary([atom_to_binary(Type, latin1), $-, Fixedname])},
					{<<"type">>, Type},
					{<<"name">>, Fixedname},
					{<<"display">>, Fixedname},
					{<<"details">>, Encodeddetail}
				]}}
			]}
	end,
	{ok, Json, State}.

encode_call(Call) ->
	Clientrec = Call#call.client,
	Client = case Clientrec#client.label of
		undefined ->
			<<"unknown client">>;
		Else ->
			list_to_binary(Else)
	end,
	{struct, [
		{<<"callerid">>, list_to_binary(element(1, Call#call.callerid) ++ " " ++ element(2, Call#call.callerid))},
		{<<"brandname">>, Client},
		{<<"skills">>, cpx_json_util:enc_skills(Call#call.skills)},
		{<<"queue">>, l2b(Call#call.queue)},
		{<<"ringpath">>, Call#call.ring_path},
		{<<"mediapath">>, Call#call.media_path},
		{<<"callid">>, list_to_binary(Call#call.id)},
		{<<"source_module">>, Call#call.source_module},
		{<<"type">>, Call#call.type},
		{<<"state_changes">>, cpx_json_util:enc_state_changes(Call#call.state_changes)}]}.

%% doc Encode the given data into a structure suitable for ejrpc2_json:encode
% -spec(encode_statedata/1 ::
% 	(Callrec :: #call{}) -> json();
% 	(Clientrec :: #client{}) -> json();
% 	({'onhold', Holdcall :: #call{}, 'calling', any()}) -> json();
% 	({Relcode :: string(), Bias :: non_neg_integer()}) -> json();
% 	('default') -> {'struct', [{binary(), 'default'}]};
% 	(List :: string()) -> binary();
% 	({}) -> 'false').
% encode_statedata(Callrec) when is_record(Callrec, call) ->
%	case Callrec#call.client of
%		Clientrec when is_record(Clientrec, client) ->
%			Brand = Clientrec#client.label;
%		_ ->
%			Brand = "unknown client"
%	end,
%
% encode_statedata(Clientrec) when is_record(Clientrec, client) ->
% 	Label = case Clientrec#client.label of
% 		undefined ->
% 			undefined;
% 		Else ->
% 			list_to_binary(Else)
% 	end,
% 	{struct, [
% 		{<<"brandname">>, Label}]};
% encode_statedata({onhold, Holdcall, calling, Calling}) ->
% 	Holdjson = encode_statedata(Holdcall),
% 	Callingjson = encode_statedata(Calling),
% 	{struct, [
% 		{<<"onhold">>, Holdjson},
% 		{<<"calling">>, Callingjson}]};
% encode_statedata({_, default, _}) ->
% 	{struct, [{<<"reason">>, default}]};
% encode_statedata({_, ring_fail, _}) ->
% 	{struct, [{<<"reason">>, ring_fail}]};
% encode_statedata({_, Reason, _}) ->
% 	{struct, [{<<"reason">>, list_to_binary(Reason)}]};
% encode_statedata(List) when is_list(List) ->
% 	list_to_binary(List);
% encode_statedata({}) ->
% 	false.


% extract_groups(Stats) ->
% 	extract_groups(Stats, []).

% extract_groups([], Acc) ->
% 	Acc;
% extract_groups([{{queue, _Id}, Details, _Node, _Time, _Watched, _Monref} = _Head | Tail], Acc) ->
% 	Display = proplists:get_value(group, Details),
% 	case lists:member({"queuegroup", Display}, Acc) of
% 		true ->
% 			extract_groups(Tail, Acc);
% 		false ->
% 			Top = {"queuegroup", Display},
% 			extract_groups(Tail, [Top | Acc])
% 	end;
% extract_groups([{{agent, _Id}, Details, _Node, _Time, _Watched, _Monref} = _Head | Tail], Acc) ->
% 	Display = proplists:get_value(profile, Details),
% 	case lists:member({"agentprofile", Display}, Acc) of
% 		true ->
% 			extract_groups(Tail, Acc);
% 		false ->
% 			Top = {"agentprofile", Display},
% 			extract_groups(Tail, [Top | Acc])
% 	end;
% extract_groups([_Head | Tail], Acc) ->
% 	extract_groups(Tail, Acc).



% encode_stats(Stats) ->
% 	encode_stats(Stats, 1, []).

% encode_stats([], Count, Acc) ->
% 	{Count - 1, Acc};
% encode_stats([{{Type, ProtoName}, Protodetails, Node, _Time, _Watched, _Mon} = _Head | Tail], Count, Acc) ->
% 	Display = case {ProtoName, Type} of
% 		{_Name, agent} ->
% 			Login = proplists:get_value(login, Protodetails),
% 			[{<<"display">>, list_to_binary(Login)}];
% 		{Name, _} when is_binary(Name) ->
% 			[{<<"display">>, Name}];
% 		{Name, _} when is_list(Name) ->
% 			[{<<"display">>, list_to_binary(Name)}];
% 		{Name, _} when is_atom(Name) ->
% 			[{<<"display">>, Name}]
% 	end,
% 	Id = case is_atom(ProtoName) of
% 		true ->
% 			list_to_binary(lists:flatten([atom_to_list(Type), "-", atom_to_list(ProtoName)]));
% 		false ->
% 			% Here's hoping it's a string or binary.
% 			list_to_binary(lists:flatten([atom_to_list(Type), "-", ProtoName]))
% 	end,
% 	Parent = case Type of
% 		system ->
% 			[];
% 		node ->
% 			[];
% 		agent ->
% 			[{<<"profile">>, list_to_binary(proplists:get_value(profile, Protodetails))}];
% 		queue ->
% 			[{<<"group">>, list_to_binary(proplists:get_value(group, Protodetails))}];
% 		media ->
% 			case {proplists:get_value(agent, Protodetails), proplists:get_value(queue, Protodetails)} of
% 				{undefined, undefined} ->
% 					lager:debug("Ignoring ~p as it's likely in ivr (no agent/queu)", [ProtoName]),
% 					[];
% 				{undefined, Queue} ->
% 					[{queue, list_to_binary(Queue)}];
% 				{Agent, undefined} ->
% 					[{agent, list_to_binary(Agent)}]
% 			end
% 	end,
% 	Scrubbeddetails = Protodetails,
% 	Details = [{<<"details">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, encode_proplist(Scrubbeddetails)}]}}],
% 	Encoded = lists:append([[{<<"id">>, Id}], Display, [{<<"type">>, Type}], [{node, Node}], Parent, Details]),
% 	Newacc = [{struct, Encoded} | Acc],
% 	encode_stats(Tail, Count + 1, Newacc).

% -spec(encode_groups/2 :: (Stats :: [{string(), string()}], Count :: non_neg_integer()) -> {non_neg_integer(), [tuple()]}).
% encode_groups(Stats, Count) ->
% 	%lager:debug("Stats to encode:  ~p", [Stats]),
% 	encode_groups(Stats, Count + 1, [], [], []).

% -spec(encode_groups/5 :: (Groups :: [{string(), string()}], Count :: non_neg_integer(), Acc :: [tuple()], Gotqgroup :: [string()], Gotaprof :: [string()]) -> {non_neg_integer(), [tuple()]}).
% encode_groups([], Count, Acc, Gotqgroup, Gotaprof) ->
% 	Qgroups = [{Qgroup, "queuegroup"} || #queue_group{name = Qgroup} <- call_queue_config:get_queue_groups(), lists:member(Qgroup, Gotqgroup) =:= false],
% 	Aprofs = [{Aprof, "agentprofile"} || #agent_profile{name = Aprof} <- agent_auth:get_profiles(), lists:member(Aprof, Gotaprof) =:= false],
% 	List = Qgroups ++ Aprofs,

% 	Encode = fun({Name, Type}) ->
% 		{struct, [
% 			{<<"id">>, list_to_binary(lists:append([Type, "-", Name]))},
% 			{<<"type">>, list_to_binary(Type)},
% 			{<<"display">>, list_to_binary(Name)}
% 		]}
% 	end,

% 	Encoded = lists:map(Encode, List),
% 	Newacc = lists:append([Acc, Encoded]),
% 	{Count + length(Newacc), Newacc};
% encode_groups([{Type, Name} | Tail], Count, Acc, Gotqgroup, Gotaprof) ->
% 	Out = {struct, [
% 		{<<"id">>, list_to_binary(lists:append([Type, "-", Name]))},
% 		{<<"type">>, list_to_binary(Type)},
% 		{<<"display">>, list_to_binary(Name)}
% 	]},
% 	{Ngotqgroup, Ngotaprof} = case Type of
% 		"queuegroup" ->
% 			{[Name | Gotqgroup], Gotaprof};
% 		"agentprofile" ->
% 			{Gotqgroup, [Name | Gotaprof]}
% 	end,
% 	encode_groups(Tail, Count + 1, [Out | Acc], Ngotqgroup, Ngotaprof).


encode_proplist(Proplist) ->
	Struct = encode_proplist(Proplist, []),
	{struct, Struct}.

encode_proplist([], Acc) ->
	lists:reverse(Acc);
encode_proplist([Entry | Tail], Acc) when is_atom(Entry) ->
	Newacc = [{Entry, true} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{skills, _Skills} | Tail], Acc) ->
	encode_proplist(Tail, Acc);
encode_proplist([{Key, {timestamp, Num}} | Tail], Acc) when is_integer(Num) ->
	Newacc = [{Key, {struct, [{timestamp, Num}]}} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} | Tail], Acc) when is_list(Value) ->
	Newval = list_to_binary(Value),
	Newacc = [{Key, Newval} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} = Head | Tail], Acc) when is_atom(Value), is_atom(Key) ->
	encode_proplist(Tail, [Head | Acc]);
encode_proplist([{Key, Value} | Tail], Acc) when is_binary(Value); is_float(Value); is_integer(Value) ->
	Newacc = [{Key, Value} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} | Tail], Acc) when is_record(Value, client) ->
	Label = case Value#client.label of
		undefined ->
			undefined;
		_ ->
			list_to_binary(Value#client.label)
	end,
	encode_proplist(Tail, [{Key, Label} | Acc]);
encode_proplist([{callerid, {CidName, CidDAta}} | Tail], Acc) ->
	CidNameBin = list_to_binary(CidName),
	CidDAtaBin = list_to_binary(CidDAta),
	Newacc = [{callid_name, CidNameBin} | [{callid_data, CidDAtaBin} | Acc ]],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Media} | Tail], Acc) when is_record(Media, call) ->
	Simple = [{callerid, Media#call.callerid},
	{type, Media#call.type},
	{client, Media#call.client},
	{direction, Media#call.direction},
	{id, Media#call.id}],
	Json = encode_proplist(Simple),
	encode_proplist(Tail, [{Key, Json} | Acc]);
encode_proplist([{Key, {onhold, Media, calling, Number}} | Tail], Acc) when is_record(Media, call) ->
	Simple = [
		{callerid, Media#call.callerid},
		{type, Media#call.type},
		{client, Media#call.client},
		{direction, Media#call.direction},
		{id, Media#call.id},
		{calling, list_to_binary(Number)}
	],
	Json = encode_proplist(Simple),
	encode_proplist(Tail, [{Key, Json} | Acc]);
encode_proplist([_Head | Tail], Acc) ->
	encode_proplist(Tail, Acc).
