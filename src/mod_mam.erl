%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%      Message Archive Management (XEP-0313)
%%% @end
%%% Created :  4 Jul 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2013-2015   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(mod_mam).
-on_load(init_web/0).

-protocol({xep, 313, '0.3'}).

-behaviour(gen_mod).

%% API
-export([start/2, stop/1]).

-export([user_send_packet/4, user_receive_packet/5,
	 process_iq_v0_2/3, process_iq_v0_3/3, remove_user/2,
	 remove_user/3, mod_opt_type/1, muc_process_iq/4,
	 muc_filter_message/5, process/2, make_matchspec/5]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("logger.hrl").
-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").

-record(archive_msg,
        {us = {<<"">>, <<"">>}                :: {binary(), binary()} | '$2',
         id = <<>>                            :: binary() | '_',
         timestamp = now()                    :: erlang:timestamp() | '_' | '$1',
         peer = {<<"">>, <<"">>, <<"">>}      :: ljid() | '_' | '$3',
         bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_' | '$3',
	 packet = #xmlel{}                    :: xmlel() | '_',
	 nick = <<"">>                        :: binary(),
	 type = chat                          :: chat | groupchat}).

-record(archive_prefs,
        {us = {<<"">>, <<"">>} :: {binary(), binary()},
         default = never       :: never | always | roster,
         always = []           :: [ljid()],
         never = []            :: [ljid()]}).

-record(html_msg,
       {type = text            :: text | action | join | leave | kick | ban | nick | subject | none,
        nick = <<"">>          :: binary(),
        text = <<"">>          :: binary(),
        timestamp = calendar:local_time() :: calendar:datetime(),
        ms   = 0               :: 0..999999 }).

-define(CT_HTML,
        {<<"Content-Type">>, <<"text/html; charset=utf-8">>}).
-define(HEADER, [?CT_HTML]).
-define(OK(Data), {200, ?HEADER, Data}).
-define(BAD_REQUEST, {400, ?HEADER, #xmlel{name = <<"h1">>,
                 children = [{xmlcdata,<<"400 Bad Request">>}]}}).
-define(ACC_DENIED, {403, ?HEADER, #xmlel{name = <<"h1">>,
                 children = [{xmlcdata,<<"403 Access Denied">>}]}}).
-define(NOT_FOUND, {404, ?HEADER, #xmlel{name = <<"h1">>,
                 children = [{xmlcdata,<<"404 Not Found">>}]}}).
-define(SERVER_ERROR, {503, ?HEADER, #xmlel{name = <<"h1">>,
                 children = [{xmlcdata,<<"503 Internal Server Error">>}]}}).

%%%===================================================================
%%% API
%%%===================================================================
start(Host, Opts) ->
    ?DEBUG("Starting mam for ~p", [Host]),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
                             one_queue),
    DBType = gen_mod:db_type(Host, Opts),
    init_db(DBType, Host),
    init_cache(DBType, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
                       user_receive_packet, 500),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
                       user_send_packet, 500),
    ejabberd_hooks:add(muc_filter_message, Host, ?MODULE,
		       muc_filter_message, 50),
    ejabberd_hooks:add(muc_process_iq, Host, ?MODULE,
		       muc_process_iq, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host, ?MODULE,
		       remove_user, 50),
    ok.

init_db(mnesia, _Host) ->
    mnesia:create_table(archive_msg,
                        [{disc_only_copies, [node()]},
                         {type, bag},
                         {attributes, record_info(fields, archive_msg)}]),
    mnesia:create_table(archive_prefs,
                        [{disc_only_copies, [node()]},
                         {attributes, record_info(fields, archive_prefs)}]);
init_db(_, _) ->
    ok.

init_cache(_DBType, Opts) ->
    MaxSize = gen_mod:get_opt(cache_size, Opts,
                              fun(I) when is_integer(I), I>0 -> I end,
                              1000),
    LifeTime = gen_mod:get_opt(cache_life_time, Opts,
                               fun(I) when is_integer(I), I>0 -> I end,
			       timer:hours(1) div 1000),
    cache_tab:new(archive_prefs, [{max_size, MaxSize},
				  {life_time, LifeTime}]).

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  user_send_packet, 500),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
			  user_receive_packet, 500),
    ejabberd_hooks:delete(muc_filter_message, Host, ?MODULE,
			  muc_filter_message, 50),
    ejabberd_hooks:delete(muc_process_iq, Host, ?MODULE,
			  muc_process_iq, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_0),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_0),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ok.

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
                mnesia:delete({archive_msg, US}),
                mnesia:delete({archive_prefs, US})
        end,
    mnesia:transaction(F);
remove_user(LUser, LServer, odbc) ->
    SUser = ejabberd_odbc:escape(LUser),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from archive where username='">>, SUser, <<"';">>]),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from archive_prefs where username='">>, SUser, <<"';">>]).

user_receive_packet(Pkt, C2SState, JID, Peer, _To) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt) of
        true ->
            NewPkt = strip_my_archived_tag(Pkt, LServer),
	    case store_msg(C2SState, NewPkt, LUser, LServer, Peer, recv) of
                {ok, ID} ->
                    Archived = #xmlel{name = <<"archived">>,
                                      attrs = [{<<"by">>, LServer},
                                               {<<"xmlns">>, ?NS_MAM_TMP},
                                               {<<"id">>, ID}]},
                    NewEls = [Archived|NewPkt#xmlel.children],
                    NewPkt#xmlel{children = NewEls};
                _ ->
                    NewPkt
            end;
        false ->
            Pkt
    end.

user_send_packet(Pkt, C2SState, JID, Peer) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt) of
	true ->
            NewPkt = strip_my_archived_tag(Pkt, LServer),
	    store_msg(C2SState, jlib:replace_from_to(JID, Peer, NewPkt),
		      LUser, LServer, Peer, send),
            NewPkt;
        false ->
            Pkt
    end.

muc_filter_message(Pkt, #state{config = Config} = MUCState,
		   RoomJID, From, FromNick) ->
    if Config#config.mam ->
	    NewPkt = strip_my_archived_tag(Pkt, MUCState#state.server_host),
	    store_muc(MUCState, NewPkt, RoomJID, From, FromNick),
	    NewPkt;
	true ->
	    Pkt
    end.

% Query archive v0.2
process_iq_v0_2(#jid{lserver = LServer} = From,
           #jid{lserver = LServer} = To,
           #iq{type = get, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    Fs = lists:flatmap(
		   fun(#xmlel{name = <<"start">>} = El) ->
			   [{<<"start">>, [xml:get_tag_cdata(El)]}];
		      (#xmlel{name = <<"end">>} = El) ->
			   [{<<"end">>, [xml:get_tag_cdata(El)]}];
		      (#xmlel{name = <<"with">>} = El) ->
			   [{<<"with">>, [xml:get_tag_cdata(El)]}];
		      (#xmlel{name = <<"withroom">>} = El) ->
			   [{<<"withroom">>, [xml:get_tag_cdata(El)]}];
		      (#xmlel{name = <<"withtext">>} = El) ->
			   [{<<"withtext">>, [xml:get_tag_cdata(El)]}];
		      (#xmlel{name = <<"set">>}) ->
			   [{<<"set">>, SubEl}];
		      (_) ->
			   []
	   end, SubEl#xmlel.children),
    process_iq(LServer, From, To, IQ, SubEl, Fs, chat);
process_iq_v0_2(From, To, IQ) ->
    process_iq(From, To, IQ).

% Query archive v0.3
process_iq_v0_3(#jid{lserver = LServer} = From,
	   #jid{lserver = LServer} = To,
	   #iq{type = set, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    process_iq(LServer, From, To, IQ, SubEl, get_xdata_fields(SubEl), chat);
process_iq_v0_3(From, To, IQ) ->
    process_iq(From, To, IQ).

muc_process_iq(#iq{type = set,
		   sub_el = #xmlel{name = <<"query">>,
				   attrs = Attrs} = SubEl} = IQ,
	       MUCState, From, To) ->
    case xml:get_attr_s(<<"xmlns">>, Attrs) of
	?NS_MAM_0 ->
	    LServer = MUCState#state.server_host,
	    Role = mod_muc_room:get_role(From, MUCState),
	    process_iq(LServer, From, To, IQ, SubEl,
		       get_xdata_fields(SubEl), {groupchat, Role});
	_ ->
	    IQ
    end;
muc_process_iq(IQ, _MUCState, _From, _To) ->
    IQ.

get_xdata_fields(SubEl) ->
    case {xml:get_subtag_with_xmlns(SubEl, <<"x">>, ?NS_XDATA),
		       xml:get_subtag_with_xmlns(SubEl, <<"set">>, ?NS_RSM)} of
		     {#xmlel{} = XData, false} ->
			 jlib:parse_xdata_submit(XData);
		     {#xmlel{} = XData, #xmlel{}} ->
			 [{<<"set">>, SubEl} | jlib:parse_xdata_submit(XData)];
		     {false, #xmlel{}} ->
			 [{<<"set">>, SubEl}];
		     {false, false} ->
			 []
    end.


process([<<"conferences">>], #request{method = 'GET'} = R) ->
    %TODO: conf options to manage logs access
    MUC_server = case proplists:get_value(<<"Muc-Host">>, R#request.headers) of 
        undefined -> case lists:member(R#request.host, ?MYHOSTS) of
                         true -> R#request.host;
                         false -> lists:nth(1, ?MYHOSTS)
                     end;
                H -> H
    end,
    Rooms = [ binary:split(Room,<<"@">>) || Room <- mod_muc_admin:muc_online_rooms(MUC_server) ],
    case mam_web:render(conference_list, [{rooms, Rooms}]) of
        {ok, Data} -> ?OK(Data);
        _ -> ?SERVER_ERROR
    end;

process([<<"conferences">>, MUC_Name | T], _R=#request{method = 'GET'}) ->
    MUC = binary:split(MUC_Name,[<<"@">>]),
    case muc_logs_enabled(MUC) of
        true -> render_muc_mam(MUC, T);
        false -> ?NOT_FOUND
    end;

process([<<"users">> | _], #request{method = 'GET'}) ->
    %TODO: list user logs. AAA
    {204, ?HEADER,
     #xmlel{name = <<"h1">>, 
            children = [{xmlcdata,<<"">> }]}};

%% Some "default behaviour" functions.
process([], #request{method = 'OPTIONS', data = <<>>}) ->
    {200, [], <<>>};
process([], #request{method = 'HEAD'}) ->
    ?OK(<<>>);
process(_Path, _Request) ->
    ?DEBUG("Bad Request at ~p: ~p", [_Path, _Request]),
    ?BAD_REQUEST.

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_room_options(MUC_name, MUC_server) ->
    case binary:split(<<".">>, MUC_server) of
        [MS,LS] -> mod_muc:restore_room(LS, MUC_server, MUC_name);
        _       -> []
    end.
        
muc_logs_enabled([MUC_jid, MUC_server]) ->
    proplists:get_bool(mam, 
                       mod_muc_admin:get_room_options(MUC_jid, MUC_server));
muc_logs_enabled(_) -> false .
muc_title([MUC_jid, MUC_server]) ->
    case proplists:lookup(title, 
                       mod_muc_admin:get_room_options(MUC_jid, MUC_server)) of
        none -> {title, join([MUC_jid, MUC_server],<<"@">>)};
        Title -> Title
    end;
muc_title(_) -> {title,<<>>}.
muc_description([MUC_jid, MUC_server]) ->
    case proplists:lookup(description,
                       mod_muc_admin:get_room_options(MUC_jid, MUC_server)) of
        none -> {description, <<>>};
        Desc -> Desc
    end;
muc_description(_) -> {description, <<>>}.

% list of years
render_muc_mam([MUC_jid, MUC_server] = MUC, []) -> 
     case mam_web:render(conference_years, [{muc_name, join(MUC, <<"@">>)},
                    {dates, mnesia_get_distinct_dates(MUC_jid, MUC_server)},
                    {year, <<>>},
                    muc_title(MUC),
                    muc_description(MUC)
                    ]) of
         {ok, Data} -> ?OK(Data);
         _ -> ?NOT_FOUND
     end;

% list of months
render_muc_mam([MUC_jid, MUC_server] = MUC, [Y]) -> 
     case mam_web:render(conference_years, [{muc_name, join(MUC, <<"@">>)},
                    {dates, mnesia_get_distinct_dates(MUC_jid, MUC_server)},
                    {year, Y},
                    muc_title(MUC),
                    muc_description(MUC)
                    ]) of
         {ok, Data} -> ?OK(Data);
         _ -> ?NOT_FOUND
     end;


% list of days
render_muc_mam([MUC_jid, MUC_server] = MUC, [Y, M]) -> 
     Month = lists:keyfind(list_to_integer(binary:bin_to_list(M)),1,
                  proplists:get_value(list_to_integer(binary:bin_to_list(Y)),
                          mnesia_get_distinct_dates(MUC_jid, MUC_server), [])),
     case Month of 
         false -> ?NOT_FOUND;
         _Days ->
             case mam_web:render(conference_month, [{muc_name, join(MUC, <<"@">>)},
                            {year, Y},
                            {month, Month},
                             muc_title(MUC),
                             muc_description(MUC)
                            ]) of
                 {ok, Data} -> ?OK(Data);
                 _          -> ?SERVER_ERROR
             end
     end;
% day messages per day
render_muc_mam([MUC_jid, MUC_server] = MUC, [Y, M, D]) -> 
    case muc_logs_enabled(MUC) of
      true ->
        case  {str:to_integer(Y), str:to_integer(M), str:to_integer(D)} of
            {{Yi, _}, {Mi, _}, {Di, _}} when is_integer(Yi), is_integer(Mi), is_integer(Di) ->
                case calendar:valid_date(Yi, Mi, Di) of
                  false -> ?NOT_FOUND;
                   true ->
                     Seconds = calendar:datetime_to_gregorian_seconds(
                                     {{Yi,Mi,Di}, {0,0,0}}) - 62167219200,
                     Start = {Seconds div 1000000, Seconds rem 1000000, 0},
                     EndSeconds = Seconds + 86400,
                     End = {EndSeconds div 1000000, EndSeconds rem 1000000, 0}, 
                     MS = make_matchspec(MUC_jid, MUC_server, Start, End, none),
                     Msgs = mnesia:dirty_select(archive_msg, MS),
                     
                     case mam_web:render(conference_day, [
                           {header, join(MUC,<<"@">>) },
                            muc_title(MUC),
                            muc_description(MUC),
                           {messages, 
                            lists:map(fun archive_to_html_message/1, Msgs)}
                                                                           ]) of
                         {ok, Data} -> ?OK(Data);
                         _          -> ?DEBUG("Internal server error rendering",[]),
                                       ?SERVER_ERROR
                     end
                end;
             _ -> ?NOT_FOUND
        end;
      false -> ?ACC_DENIED
    end;

% catch all case
render_muc_mam(_MUC, _Tail) ->
    ?DEBUG("Got wrong request for ~p, with tail ~p.", [_MUC, _Tail]),
    ?NOT_FOUND.
    
mnesia_get_distinct_dates(MJid, MServ) ->
    Dates_of_messages = fun (E, S) ->
            case E of
                #archive_msg{us={MJid, MServ}} ->
                    {{Y,M,D},_} = calendar:now_to_universal_time(
                                                      E#archive_msg.timestamp),
                    case dict:is_key(Y,S) of
			true -> Months = dict:fetch(Y, S);
                        false -> Months = dict:new()
                    end,
                    case dict:is_key(M, Months) of
                        true -> Days = dict:fetch(M, Months);
                        false -> Days = sets:new()
                    end,
                    dict:store(Y, dict:store(M, 
                                        sets:add_element(D, Days), Months), S);
				
                _ -> S
            end
        end,
    case mnesia:transaction(fun mnesia:foldl/3, 
                            [Dates_of_messages, dict:new(), archive_msg]) of
        {atomic, Dates} -> lists:map(fun({Y,D}) -> {Y, lists:map(
				   fun({M,S}) -> 
                                   {M, sets:to_list(S), {{Y,M,0},{0,0,0}}} end,
                                   dict:to_list(D))} end, dict:to_list(Dates));
        {error, _Reason} -> 
                ?DEBUG("Request to mnesia for messages date failed with ~p",
                                      [_Reason]), 
                []
    end.

archive_to_html_message(#archive_msg{} = Msg) ->
    {Type, Txt} = 
      case {xml:get_subtag(Msg#archive_msg.packet, <<"subject">>),
            xml:get_subtag(Msg#archive_msg.packet, <<"body">>)}
          of
        {false, false} -> {none,<<>>};
        {false, SubEl} -> case  xml:get_tag_cdata(SubEl) of
                          <<"/me ", T/binary>> -> {action, T};
                                             T -> {text, T}
                          end;
        {SubEl, _} -> {subject, xml:get_tag_cdata(SubEl)}
      end,
    #html_msg{type = Type,
         nick = Msg#archive_msg.nick,
         timestamp = calendar:now_to_local_time(Msg#archive_msg.timestamp),
         ms = element(3, Msg#archive_msg.timestamp),
         text = Txt
    }.

% Preference setting (both v0.2 & v0.3)
process_iq(#jid{luser = LUser, lserver = LServer},
           #jid{lserver = LServer},
           #iq{type = set, sub_el = #xmlel{name = <<"prefs">>} = SubEl} = IQ) ->
    try {case xml:get_tag_attr_s(<<"default">>, SubEl) of
             <<"always">> -> always;
             <<"never">> -> never;
             <<"roster">> -> roster
         end,
         lists:foldl(
           fun(#xmlel{name = <<"always">>, children = Els}, {A, N}) ->
                   {get_jids(Els) ++ A, N};
              (#xmlel{name = <<"never">>, children = Els}, {A, N}) ->
                   {A, get_jids(Els) ++ N};
              (_, {A, N}) ->
                   {A, N}
           end, {[], []}, SubEl#xmlel.children)} of
        {Default, {Always, Never}} ->
            case write_prefs(LUser, LServer, LServer, Default,
                             lists:usort(Always), lists:usort(Never)) of
                ok ->
                    IQ#iq{type = result, sub_el = []};
                _Err ->
                    IQ#iq{type = error,
                          sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
            end
    catch _:_ ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end;
process_iq(_, _, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.

process_iq(LServer, From, To, IQ, SubEl, Fs, MsgType) ->
    case catch lists:foldl(
		 fun({<<"start">>, [Data|_]}, {_, End, With, RSM}) ->
			 {{_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  End, With, RSM};
		    ({<<"end">>, [Data|_]}, {Start, _, With, RSM}) ->
			 {Start,
			  {_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  With, RSM};
		    ({<<"with">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, jlib:jid_tolower(jlib:string_to_jid(Data)), RSM};
		    ({<<"withroom">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End,
			  {room, jlib:jid_tolower(jlib:string_to_jid(Data))},
			  RSM};
		    ({<<"withtext">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, {text, Data}, RSM};
		    ({<<"set">>, El}, {Start, End, With, _}) ->
			 {Start, End, With, jlib:rsm_decode(El)};
		    (_, Acc) ->
			 Acc
		 end, {none, [], none, none}, Fs) of
	{'EXIT', _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]};
	{Start, End, With, RSM} ->
	    select_and_send(LServer, From, To, Start, End,
			    With, RSM, IQ, MsgType)
    end.

should_archive(#xmlel{name = <<"message">>} = Pkt) ->
    case {xml:get_attr_s(<<"type">>, Pkt#xmlel.attrs),
          xml:get_subtag_cdata(Pkt, <<"body">>)} of
        {<<"error">>, _} ->
            false;
        {<<"groupchat">>, _} ->
	    false;
        {_, <<>>} ->
            %% Empty body
            false;
        _ ->
            true
    end;
should_archive(#xmlel{}) ->
    false.

strip_my_archived_tag(Pkt, LServer) ->
    NewEls = lists:filter(
               fun(#xmlel{name = <<"archived">>,
                          attrs = Attrs}) ->
                       case catch jlib:nameprep(
                                    xml:get_attr_s(
                                      <<"by">>, Attrs)) of
                           LServer ->
                               false;
                           _ ->
                               true
                       end;
                  (_) ->
                       true
               end, Pkt#xmlel.children),
    Pkt#xmlel{children = NewEls}.

should_archive_peer(C2SState,
                    #archive_prefs{default = Default,
                                   always = Always,
                                   never = Never},
                    Peer) ->
    LPeer = jlib:jid_tolower(Peer),
    case lists:member(LPeer, Always) of
        true ->
            true;
        false ->
            case lists:member(LPeer, Never) of
                true ->
                    false;
                false ->
                    case Default of
                        always -> true;
                        never -> false;
                        roster ->
                            case ejabberd_c2s:get_subscription(
                                   LPeer, C2SState) of
                                both -> true;
                                from -> true;
                                to -> true;
                                _ -> false
                            end
                    end
            end
    end.

should_archive_muc(_MUCState, _Peer) ->
    %% TODO
    true.

store_msg(C2SState, Pkt, LUser, LServer, Peer, Dir) ->
    Prefs = get_prefs(LUser, LServer),
    case should_archive_peer(C2SState, Prefs, Peer) of
        true ->
	    US = {LUser, LServer},
	    store(Pkt, LServer, US, chat, Peer, <<"">>, Dir,
                     gen_mod:db_type(LServer, ?MODULE));
        false ->
            pass
    end.

store_muc(MUCState, Pkt, RoomJID, Peer, Nick) ->
    case should_archive_muc(MUCState, Peer) of
	true ->
	    LServer = MUCState#state.server_host,
	    {U, S, _} = jlib:jid_tolower(RoomJID),
	    store(Pkt, LServer, {U, S}, groupchat, Peer, Nick, recv,
		  gen_mod:db_type(LServer, ?MODULE));
	false ->
	    pass
    end.

store(Pkt, _, {LUser, LServer}, Type, Peer, Nick, _Dir, mnesia) ->
    LPeer = {PUser, PServer, _} = jlib:jid_tolower(Peer),
    TS = now(),
    ID = jlib:integer_to_binary(now_to_usec(TS)),
    case mnesia:dirty_write(
	   #archive_msg{us = {LUser, LServer},
                        id = ID,
                        timestamp = TS,
                        peer = LPeer,
                        bare_peer = {PUser, PServer, <<>>},
			type = Type,
			nick = Nick,
                        packet = Pkt}) of
        ok ->
            {ok, ID};
        Err ->
            Err
    end;
store(Pkt, LServer, {LUser, LHost}, Type, Peer, Nick, _Dir, odbc) ->
    TSinteger = now_to_usec(now()),
    ID = TS = jlib:integer_to_binary(TSinteger),
    SUser = case Type of
		chat -> LUser;
		groupchat -> jlib:jid_to_string({LUser, LHost, <<>>})
	    end,
    BarePeer = jlib:jid_to_string(
                 jlib:jid_tolower(
                   jlib:jid_remove_resource(Peer))),
    LPeer = jlib:jid_to_string(
              jlib:jid_tolower(Peer)),
    XML = xml:element_to_binary(Pkt),
    Body = xml:get_subtag_cdata(Pkt, <<"body">>),
    case ejabberd_odbc:sql_query(
           LServer,
           [<<"insert into archive (username, timestamp, "
	      "peer, bare_peer, xml, txt, kind, nick) values (">>,
	    <<"'">>, ejabberd_odbc:escape(SUser), <<"', ">>,
            <<"'">>, TS, <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(LPeer), <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(BarePeer), <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(XML), <<"', ">>,
	    <<"'">>, ejabberd_odbc:escape(Body), <<"', ">>,
	    <<"'">>, jlib:atom_to_binary(Type), <<"', ">>,
	    <<"'">>, ejabberd_odbc:escape(Nick), <<"');">>]) of
        {updated, _} ->
            {ok, ID};
        Err ->
            Err
    end.

write_prefs(LUser, LServer, Host, Default, Always, Never) ->
    DBType = case gen_mod:db_type(Host, ?MODULE) of
		 odbc -> {odbc, Host};
		 DB -> DB
	     end,
    Prefs = #archive_prefs{us = {LUser, LServer},
                           default = Default,
                           always = Always,
                           never = Never},
    cache_tab:dirty_insert(
      archive_prefs, {LUser, LServer}, Prefs,
      fun() ->  write_prefs(LUser, LServer, Prefs, DBType) end).

write_prefs(_LUser, _LServer, Prefs, mnesia) ->
    mnesia:dirty_write(Prefs);
write_prefs(LUser, _LServer, #archive_prefs{default = Default,
                                           never = Never,
                                           always = Always},
            {odbc, Host}) ->
    SUser = ejabberd_odbc:escape(LUser),
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = ejabberd_odbc:encode_term(Always),
    SNever = ejabberd_odbc:encode_term(Never),
    case update(Host, <<"archive_prefs">>,
                [<<"username">>, <<"def">>, <<"always">>, <<"never">>],
                [SUser, SDefault, SAlways, SNever],
                [<<"username='">>, SUser, <<"'">>]) of
        {updated, _} ->
            ok;
        Err ->
            Err
    end.

get_prefs(LUser, LServer) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Res = cache_tab:lookup(archive_prefs, {LUser, LServer},
			   fun() -> get_prefs(LUser, LServer,
					      DBType)
			   end),
    case Res of
        {ok, Prefs} ->
            Prefs;
        error ->
            Default = gen_mod:get_module_opt(
                        LServer, ?MODULE, default,
                        fun(always) -> always;
                           (never) -> never;
                           (roster) -> roster
                        end, never),
            #archive_prefs{us = {LUser, LServer}, default = Default}
    end.

get_prefs(LUser, LServer, mnesia) ->
    case mnesia:dirty_read(archive_prefs, {LUser, LServer}) of
        [Prefs] ->
            {ok, Prefs};
        _ ->
            error
    end;
get_prefs(LUser, LServer, odbc) ->
    case ejabberd_odbc:sql_query(
	   LServer,
	   [<<"select def, always, never from archive_prefs ">>,
	    <<"where username='">>,
	    ejabberd_odbc:escape(LUser), <<"';">>]) of
        {selected, _, [[SDefault, SAlways, SNever]]} ->
            Default = erlang:binary_to_existing_atom(SDefault, utf8),
            Always = ejabberd_odbc:decode_term(SAlways),
            Never = ejabberd_odbc:decode_term(SNever),
            {ok, #archive_prefs{us = {LUser, LServer},
                                default = Default,
                                always = Always,
                                never = Never}};
        _ ->
            error
    end.

select_and_send(LServer, From, To, Start, End, With, RSM, IQ, MsgType) ->
    DBType = case gen_mod:db_type(LServer, ?MODULE) of
		 odbc -> {odbc, LServer};
		 DB -> DB
	     end,
    select_and_send(LServer, From, To, Start, End, With, RSM, IQ,
		    MsgType, DBType).

select_and_send(LServer, From, To, Start, End, With, RSM, IQ, MsgType, DBType) ->
    {Msgs, IsComplete, Count} = select_and_start(LServer, From, To, Start, End,
						 With, RSM, MsgType, DBType),
    SortedMsgs = lists:keysort(2, Msgs),
    send(From, To, SortedMsgs, RSM, Count, IsComplete, IQ).

select_and_start(LServer, From, To, Start, End, With, RSM, MsgType, DBType) ->
    case MsgType of
	chat ->
	    case With of
		{room, {_, _, <<"">>} = WithJID} ->
		    select(LServer, jlib:make_jid(WithJID), Start, End,
			   WithJID, RSM, MsgType, DBType);
	_ ->
		    select(LServer, From, Start, End,
			   With, RSM, MsgType, DBType)
	    end;
	{groupchat, _Role} ->
	    select(LServer, To, Start, End, With, RSM, MsgType, DBType)
    end.

select(_LServer, #jid{luser = LUser, lserver = LServer} = JidRequestor,
       Start, End, With, RSM, MsgType, mnesia) ->
    MS = make_matchspec(LUser, LServer, Start, End, With),
    Msgs = mnesia:dirty_select(archive_msg, MS),
    {FilteredMsgs, IsComplete} = filter_by_rsm(Msgs, RSM),
    Count = length(Msgs),
    {lists:map(
       fun(Msg) ->
               {Msg#archive_msg.id,
                jlib:binary_to_integer(Msg#archive_msg.id),
		msg_to_el(Msg, MsgType, JidRequestor)}
       end, FilteredMsgs), IsComplete, Count};
select(LServer, #jid{luser = LUser} = JidRequestor,
       Start, End, With, RSM, MsgType, {odbc, Host}) ->
    User = case MsgType of
	       chat -> LUser;
	       {groupchat, _Role} -> jlib:jid_to_string(JidRequestor)
	   end,
    {Query, CountQuery} = make_sql_query(User, LServer,
					 Start, End, With, RSM),
    % XXX TODO from XEP-0313:
    % To conserve resources, a server MAY place a reasonable limit on
    % how many stanzas may be pushed to a client in one request. If a
    % query returns a number of stanzas greater than this limit and
    % the client did not specify a limit using RSM then the server
    % should return a policy-violation error to the client.
    case {ejabberd_odbc:sql_query(Host, Query),
          ejabberd_odbc:sql_query(Host, CountQuery)} of
        {{selected, _, Res}, {selected, _, [[Count]]}} ->
	    {Max, Direction} = case RSM of
				   #rsm_in{max = M, direction = D} -> {M, D};
				   _ -> {undefined, undefined}
			       end,
	    {Res1, IsComplete} =
		if Max >= 0 andalso Max /= undefined andalso length(Res) > Max ->
			if Direction == before ->
				{lists:nthtail(1, Res), false};
			   true ->
				{lists:sublist(Res, Max), false}
			end;
		   true ->
			{Res, true}
		end,
            {lists:map(
	       fun([TS, XML, PeerBin, Kind, Nick]) ->
                       #xmlel{} = El = xml_stream:parse_element(XML),
                       Now = usec_to_now(jlib:binary_to_integer(TS)),
                       PeerJid = jlib:jid_tolower(jlib:string_to_jid(PeerBin)),
		       T = if Kind /= <<"">> ->
				   jlib:binary_to_atom(Kind);
			      true -> chat
			   end,
                       {TS, jlib:binary_to_integer(TS),
                        msg_to_el(#archive_msg{timestamp = Now,
					       packet = El,
					       type = T,
					       nick = Nick,
					       peer = PeerJid},
				  MsgType,
				  JidRequestor)}
               end, Res1), IsComplete, jlib:binary_to_integer(Count)};
	_ ->
	    {[], false, 0}
    end.

msg_to_el(#archive_msg{timestamp = TS, packet = Pkt1, nick = Nick, peer = Peer},
	  MsgType, JidRequestor) ->
    Delay = jlib:now_to_utc_string(TS),
    Pkt = maybe_update_from_to(Pkt1, JidRequestor, Peer, MsgType, Nick),
    #xmlel{name = <<"forwarded">>,
           attrs = [{<<"xmlns">>, ?NS_FORWARD}],
           children = [#xmlel{name = <<"delay">>,
                              attrs = [{<<"xmlns">>, ?NS_DELAY},
                                       {<<"stamp">>, Delay}]},
                       xml:replace_tag_attr(
                         <<"xmlns">>, <<"jabber:client">>, Pkt)]}.

maybe_update_from_to(Pkt, _JIDRequestor, undefined, _Type, _Nick) ->
    Pkt;
maybe_update_from_to(Pkt, JidRequestor, Peer, chat, _Nick) ->
    case xml:get_attr_s(<<"type">>, Pkt#xmlel.attrs) of
	<<"groupchat">> ->
	    Pkt2 = xml:replace_tag_attr(<<"to">>,
					jlib:jid_to_string(JidRequestor),
					Pkt),
	    xml:replace_tag_attr(<<"from">>, jlib:jid_to_string(Peer),
				 Pkt2);
	_ -> Pkt
    end;
maybe_update_from_to(#xmlel{children = Els} = Pkt, JidRequestor,
		     Peer, {groupchat, Role}, Nick) ->
    Items = case Role of
		moderator ->
		    [#xmlel{name = <<"x">>,
			    attrs = [{<<"xmlns">>, ?NS_MUC_USER}],
			    children =
				[#xmlel{name = <<"item">>,
					attrs = [{<<"jid">>,
						  jlib:jid_to_string(Peer)}]}]}];
		_ ->
		    []
	    end,
    Pkt1 = Pkt#xmlel{children = Items ++ Els},
    Pkt2 = jlib:replace_from(jlib:jid_replace_resource(JidRequestor, Nick), Pkt1),
    jlib:remove_attr(<<"to">>, Pkt2).

send(From, To, Msgs, RSM, Count, IsComplete, #iq{sub_el = SubEl} = IQ) ->
    QID = xml:get_tag_attr_s(<<"queryid">>, SubEl),
    NS = xml:get_tag_attr_s(<<"xmlns">>, SubEl),
    QIDAttr = if QID /= <<>> ->
		      [{<<"queryid">>, QID}];
		 true ->
		    []
	      end,
    CompleteAttr = if NS == ?NS_MAM_TMP ->
			   [];
		      NS == ?NS_MAM_0 ->
			   [{<<"complete">>, jlib:atom_to_binary(IsComplete)}]
		   end,
    Els = lists:map(
	    fun({ID, _IDInt, El}) ->
		    #xmlel{name = <<"message">>,
			   children = [#xmlel{name = <<"result">>,
					      attrs = [{<<"xmlns">>, NS},
						       {<<"id">>, ID}|QIDAttr],
					      children = [El]}]}
	    end, Msgs),
    RSMOut = make_rsm_out(Msgs, RSM, Count, QIDAttr ++ CompleteAttr, NS),
    case NS of
	?NS_MAM_TMP ->
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    IQ#iq{type = result, sub_el = RSMOut};
	?NS_MAM_0 ->
	    ejabberd_router:route(
	      To, From, jlib:iq_to_xml(IQ#iq{type = result, sub_el = []})),
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    ejabberd_router:route(
	      To, From, #xmlel{name = <<"message">>,
			       children = RSMOut}),
	    ignore
    end.


make_rsm_out([], _, Count, Attrs, NS) ->
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(#rsm_out{count = Count})}];
make_rsm_out([{FirstID, _, _}|_] = Msgs, _, Count, Attrs, NS) ->
    {LastID, _, _} = lists:last(Msgs),
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(
			 #rsm_out{first = FirstID, count = Count,
				  last = LastID})}].

filter_by_rsm(Msgs, none) ->
    {Msgs, true};
filter_by_rsm(_Msgs, #rsm_in{max = Max}) when Max < 0 ->
    {[], true};
filter_by_rsm(Msgs, #rsm_in{max = Max, direction = Direction, id = ID}) ->
    NewMsgs = case Direction of
		  aft when ID /= <<"">> ->
		      lists:filter(
			fun(#archive_msg{id = I}) ->
				I > ID
			end, Msgs);
		  before when ID /= <<"">> ->
		      lists:foldl(
			fun(#archive_msg{id = I} = Msg, Acc) when I < ID ->
				[Msg|Acc];
			   (_, Acc) ->
				Acc
			end, [], Msgs);
		  before when ID == <<"">> ->
		      lists:reverse(Msgs);
		  _ ->
		      Msgs
	      end,
    filter_by_max(NewMsgs, Max).

filter_by_max(Msgs, undefined) ->
    {Msgs, true};
filter_by_max(Msgs, Len) when is_integer(Len), Len >= 0 ->
    {lists:sublist(Msgs, Len), length(Msgs) =< Len};
filter_by_max(_Msgs, _Junk) ->
    {[], true}.

make_matchspec(LUser, LServer, Start, End, {_, _, <<>>} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
                       us = US,
                       bare_peer = BPeer} = Msg)
            when Start =< TS, End >= TS,
                 US == {LUser, LServer},
                 BPeer == With ->
              Msg
      end);
make_matchspec(LUser, LServer, Start, End, {_, _, _} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
                       us = US,
                       peer = Peer} = Msg)
            when Start =< TS, End >= TS,
                 US == {LUser, LServer},
                 Peer == With ->
              Msg
      end);
make_matchspec(LUser, LServer, Start, End, none) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
                       us = US,
                       peer = Peer} = Msg)
            when Start =< TS, End >= TS,
                 US == {LUser, LServer} ->
              Msg
      end).

make_sql_query(User, _LServer, Start, End, With, RSM) ->
    {Max, Direction, ID} = case RSM of
                               #rsm_in{} ->
                                   {RSM#rsm_in.max,
                                    RSM#rsm_in.direction,
                                    RSM#rsm_in.id};
                               none ->
                                   {none, none, <<>>}
                           end,
    LimitClause = if is_integer(Max), Max >= 0 ->
			  [<<" limit ">>, jlib:integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    WithClause = case With of
		     {text, <<>>} ->
			 [];
		     {text, Txt} ->
			 [<<" and match (txt) against ('">>,
			  ejabberd_odbc:escape(Txt), <<"')">>];
		     {_, _, <<>>} ->
			 [<<" and bare_peer='">>,
			  ejabberd_odbc:escape(jlib:jid_to_string(With)),
			  <<"'">>];
		     {_, _, _} ->
			 [<<" and peer='">>,
			  ejabberd_odbc:escape(jlib:jid_to_string(With)),
			  <<"'">>];
		     none ->
			 []
		 end,
    PageClause = case catch jlib:binary_to_integer(ID) of
		     I when is_integer(I), I >= 0 ->
			 case Direction of
			     before ->
				 [<<" AND timestamp < ">>, ID];
			     aft ->
				 [<<" AND timestamp > ">>, ID];
			     _ ->
				 []
			 end;
		     _ ->
			 []
		 end,
    StartClause = case Start of
                      {_, _, _} ->
                          [<<" and timestamp >= ">>,
                           jlib:integer_to_binary(now_to_usec(Start))];
                      _ ->
                          []
                  end,
    EndClause = case End of
                    {_, _, _} ->
                        [<<" and timestamp <= ">>,
                         jlib:integer_to_binary(now_to_usec(End))];
                    _ ->
                        []
                end,
    SUser = ejabberd_odbc:escape(User),

    Query = [<<"SELECT timestamp, xml, peer, kind, nick"
	      " FROM archive WHERE username='">>,
	     SUser, <<"'">>, WithClause, StartClause, EndClause,
	     PageClause],

    QueryPage =
	case Direction of
	    before ->
		% ID can be empty because of
		% XEP-0059: Result Set Management
		% 2.5 Requesting the Last Page in a Result Set
		[<<"SELECT timestamp, xml, peer, kind, nick FROM (">>, Query,
		 <<" ORDER BY timestamp DESC ">>,
		 LimitClause, <<") AS t ORDER BY timestamp ASC;">>];
	    _ ->
		[Query, <<" ORDER BY timestamp ASC ">>,
		 LimitClause, <<";">>]
	end,
    {QueryPage,
     [<<"SELECT COUNT(*) FROM archive WHERE username='">>,
      SUser, <<"'">>, WithClause, StartClause, EndClause, <<";">>]}.

now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

get_jids(Els) ->
    lists:flatmap(
      fun(#xmlel{name = <<"jid">>} = El) ->
              J = jlib:string_to_jid(xml:get_tag_cdata(El)),
              [jlib:jid_tolower(jlib:jid_remove_resource(J)),
               jlib:jid_tolower(J)];
         (_) ->
              []
      end, Els).

update(LServer, Table, Fields, Vals, Where) ->
    UPairs = lists:zipwith(fun (A, B) ->
				   <<A/binary, "='", B/binary, "'">>
			   end,
			   Fields, Vals),
    case ejabberd_odbc:sql_query(LServer,
				 [<<"update ">>, Table, <<" set ">>,
				  join(UPairs, <<", ">>), <<" where ">>, Where,
				  <<";">>])
	of
	{updated, 1} -> {updated, 1};
	_ ->
	    ejabberd_odbc:sql_query(LServer,
				    [<<"insert into ">>, Table, <<"(">>,
				     join(Fields, <<", ">>), <<") values ('">>,
				     join(Vals, <<"', '">>), <<"');">>])
    end.

%% Almost a copy of string:join/2.
join([], _Sep) -> [];
join([H | T], Sep) -> [H, [[Sep, X] || X <- T]].

mod_opt_type(cache_life_time) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(cache_size) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(default) ->
    fun (always) -> always;
	(never) -> never;
	(roster) -> roster
    end;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(store_body_only) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) ->
    [cache_life_time, cache_size, db_type, default, iqdisc,
     store_body_only].

init_web() -> 
    ?DEBUG("Compiling web templates for MAM",[]),
    erlydtl:compile_dir("templates/mam/", mam_web, [{record_info, [{html_msg, record_info(fields, html_msg) }] }] ), ok.
%    ?DEBUG("~p", [erlydtl:compile("templates/mam/conferences.html", mucs_list)]),
%    ?DEBUG("~p", [erlydtl:compile("templates/mam/conference.month.html", muc_month)]),
%    ?DEBUG("~p", [erlydtl:compile("templates/mam/mam.logs.list.html", log_list_template,[{record_info, [{html_msg, record_info(fields, html_msg)}]}])]),
%    ?DEBUG("~p", [erlydtl:compile("templates/mam/conference.years.html", muc_years,[{record_info, [{archive_msg, record_info(fields, archive_msg)}]}])]), ok.
