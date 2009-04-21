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

%% @doc Helper module for freeswitch media to make an outbound call.
-module(freeswitch_outbound).
-author("Micah").

-behaviour(gen_server).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("queue.hrl").
-include("call.hrl").
-include("agent.hrl").


%% API
-export([
	start_link/6,
	start/6,
	hangup/1
	]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	cnode :: atom(),
	uuid :: any(),
	agent_pid :: pid(),
	callrec :: #call{}
	}).

%%====================================================================
%% API
%%====================================================================
start(Fnode, AgentRec, Apid, Number, Ringout, Domain) when is_pid(Apid) ->
	gen_server:start(?MODULE, [Fnode, AgentRec, Apid, Number, Ringout, Domain], []).

start_link(Fnode, AgentRec, Apid, Number, Ringout, Domain) when is_pid(Apid) ->
	gen_server:start_link(?MODULE, [Fnode, AgentRec, Apid, Number, Ringout, Domain], []).

hangup(Pid) ->
	gen_server:cast(Pid, hangup).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Fnode, AgentRec, Apid, Number, Ringout, _Domain]) ->
	case freeswitch:api(Fnode, create_uuid) of
		{ok, UUID} ->
			Call = #call{id=UUID, source=self(), type=voice},
			Args = "[hangup_after_bridge=true,origination_uuid=" ++ UUID ++ ",originate_timeout=" ++ integer_to_list(Ringout) ++ "]user/" ++ AgentRec#agent.login ++ " " ++ Number ++ " xml outbound",
			?INFO("Originating outbound call with args: ~p", [Args]),
			F = fun(ok, _Reply) ->
					% agent picked up?
					%agent:set_state(Apid, outgoing, Call);
					ok;
				(error, Reply) ->
					?WARNING("originate failed: ~p", [Reply]),
					agent:set_state(Apid, idle)
			end,
			case freeswitch:bgapi(Fnode, originate, Args, F) of
				ok ->
					Gethandle = fun(Recusef, Count) ->
						?DEBUG("Counted ~p", [Count]),
						case freeswitch:handlecall(Fnode, UUID) of
							{error, badsession} when Count > 4 ->
								{error, badsession};
							{error, badsession} ->
								timer:sleep(100),
								Recusef(Recusef, Count+1);
							{error, Other} ->
								{error, Other};
							Else ->
								Else
						end
					end,
					case Gethandle(Gethandle, 0) of
						{error, badsession} ->
							?ERROR("bad uuid ~p", [UUID]),
							{stop, {error, session}};
						{error, Other} ->
							?ERROR("other error starting; ~p", [Other]),
							{stop, {error, Other}};
						_Else ->
							?DEBUG("starting for ~p", [UUID]),
							{ok, #state{cnode = Fnode, uuid = UUID, agent_pid = Apid, callrec = Call}}
					end;
				Else ->
					?ERROR("bgapi call failed ~p", [Else]),
					{stop, {error, Else}}
			end
	end.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(Request, _From, State) ->
	Reply = {unknown, Request},
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(hangup, #state{uuid = UUID} = State) ->
	freeswitch:sendmsg(State#state.cnode, UUID,
		[{"call-command", "hangup"},
			{"hangup-cause", "NORMAL_CLEARING"}]),
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({call, {event, [UUID | _Rest]}}, #state{uuid = UUID} = State) ->
	?DEBUG("call", []),
	{noreply, State};
handle_info({call_event, {event, [UUID | Rest]}}, #state{uuid = UUID} = State) ->
	Event = freeswitch:get_event_name(Rest),
	case Event of
		"CHANNEL_BRIDGE" ->
			?INFO("Call bridged", []),
			Call = State#state.callrec,
			case agent:set_state(State#state.agent_pid, outgoing, Call) of
				ok ->
					{noreply, State};
				invalid ->
					?WARNING("Cannot set agent ~p to oncall with media ~p", [State#state.agent_pid, Call#call.id]),
					{noreply, State}
			end;
		"CHANNEL_HANGUP" ->
			case proplists:get_value("variable_hangup_cause", Rest) of
				"NO_ROUTE_DESTINATION" ->
					?ERROR("No route to destination for outbound call", []);
				"NORMAL_CLEARING" ->
					agent:set_state(State#state.agent_pid, wrapup, State#state.callrec);
				"USER_BUSY" ->
					?WARNING("Agent's phone rejected the call", []);
				"NO_ANSWER" ->
					?NOTICE("Agent rangout on outbound call", []);
				Else ->
					?INFO("Hangup cause: ~p", [Else])
			end,
			{noreply, State};
		_Else ->
			?DEBUG("call_event ~p", [Event]),
			{noreply, State}
	end;
handle_info(call_hangup, State) ->
	?DEBUG("Call hangup info", []),
	{stop, normal, State};
handle_info(Info, State) ->
	?DEBUG("unhandled info ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
	?NOTICE("FreeSWITCH outbound channel teminating ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
