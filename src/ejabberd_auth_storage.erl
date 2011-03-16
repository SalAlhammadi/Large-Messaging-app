%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_storage.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>, Stephan Maka
%%% Purpose : Authentification via gen_storage
%%% Created : 12 Dec 2004 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

%%% Database schema (version / storage / table)
%%%
%%% 2.1.x / mnesia / passwd
%%%  us = {Username::string(), Host::string()}
%%%  password = string()
%%%
%%% 2.1.x / odbc / users
%%%  username = varchar250
%%%  password = text
%%%
%%% 3.0.0-prealpha / mnesia / passwd
%%%  Same as 2.1.x
%%%
%%% 3.0.0-prealpha / odbc / users
%%%  Same as 2.1.x
%%%
%%% 3.0.0-alpha / mnesia / passwd
%%%  user_host = {Username::string(), Host::string()}
%%%  password = string()
%%%
%%% 3.0.0-alpha / odbc / passwd
%%%  user = varchar150
%%%  host = varchar150
%%%  password = text

-module(ejabberd_auth_storage).
-author('alexey@process-one.net').

%% External exports
-export([start/1,
	 stop/1,
	 set_password/3,
	 check_password/3,
	 check_password/5,
	 try_register/3,
	 dirty_get_registered_users/0,
	 get_vh_registered_users/1,
	 get_vh_registered_users/2,
	 get_vh_registered_users_number/1,
	 get_vh_registered_users_number/2,
	 get_password/2,
	 get_password_s/2,
	 is_user_exists/2,
	 remove_user/2,
	 remove_user/3,
	 plain_password_required/0
	]).

-include("ejabberd.hrl").

-record(passwd, {user_host, password}).
-record(reg_users_counter, {vhost, count}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%% @spec (Host) -> ok
%%     Host = string()

start(Host) ->
    Backend =
	case ejabberd_config:get_local_option({auth_storage, Host}) of
	    undefined -> mnesia;
	    B -> B
	end,
    HostB = list_to_binary(Host),
    gen_storage:create_table(Backend, HostB, passwd,
			     [{odbc_host, Host},
			      {disc_copies, [node()]},
			      {attributes, record_info(fields, passwd)},
			      {types, [{user_host, {text, text}}]}
			     ]),
    update_table(Host, Backend),
    mnesia:create_table(reg_users_counter,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, reg_users_counter)}]),
    update_reg_users_counter_table(Host),
    ok.

stop(_Host) ->
    ok.

update_reg_users_counter_table(Server) ->
    Set = get_vh_registered_users(Server),
    Size = length(Set),
    LServer = exmpp_jid:prep_domain(exmpp_jid:parse(Server)),
    F = fun() ->
        mnesia:write(#reg_users_counter{vhost = LServer,
					count = Size})
    end,
    mnesia:sync_dirty(F).

%% @spec () -> bool()

plain_password_required() ->
    false.

%% @spec (User, Server, Password) -> bool()
%%     User = string()
%%     Server = string()
%%     Password = string()

check_password(User, Server, Password) ->
    LUser = exmpp_stringprep:nodeprep(User),
    LServer = exmpp_stringprep:nameprep(Server),
    US = {LUser, LServer},
    case catch gen_storage:dirty_read(LServer, {passwd, US}) of
	[#passwd{password = Password}] ->
	    Password /= "";
	_ ->
	    false
    end.

%% @spec (User, Server, Password, Digest, DigestGen) -> bool()
%%     User = string()
%%     Server = string()
%%     Password = string()
%%     Digest = string()
%%     DigestGen = function()

check_password(User, Server, Password, Digest, DigestGen) ->
    LUser = exmpp_stringprep:nodeprep(User),
    LServer = exmpp_stringprep:nameprep(Server),
    US = {LUser, LServer},
    case catch gen_storage:dirty_read(LServer, {passwd, US}) of
	[#passwd{password = Passwd}] ->
	    DigRes = if
			 Digest /= "" ->
			     Digest == DigestGen(Passwd);
			 true ->
			     false
		     end,
	    if DigRes ->
		    true;
	       true ->
		    (Passwd == Password) and (Password /= "")
	    end;
	_ ->
	    false
    end.

%% @spec (User, Server, Password) -> ok | {error, invalid_jid}
%%     User = string()
%%     Server = string()
%%     Password = string()

set_password(User, Server, Password) ->
    LUser = (catch exmpp_stringprep:nodeprep(User)),
    LServer = (catch exmpp_stringprep:nameprep(Server)),
    case {LUser, LServer} of
	{{stringprep, _, invalid_string, _}, _} ->
	    {error, invalid_jid};
	{_, {stringprep, _, invalid_string, _}} ->
	    {error, invalid_jid};
	US ->
	    %% TODO: why is this a transaction?
	    F = fun() ->
			gen_storage:write(LServer,
					  #passwd{user_host = US,
						  password = Password})
		end,
	    {atomic, ok} = gen_storage:transaction(LServer, passwd, F),
	    ok
    end.

%% @spec (User, Server, Password) -> {atomic, ok} | {atomic, exists} | {error, invalid_jid} | {aborted, Reason}
%%     User = string()
%%     Server = string()
%%     Password = string()

try_register(User, Server, Password) ->
    LUser = (catch exmpp_stringprep:nodeprep(User)),
    LServer = (catch exmpp_stringprep:nameprep(Server)),
    case {LUser, LServer} of
	{{stringprep, _, invalid_string, _}, _} ->
	    {error, invalid_jid};
	{_, {stringprep, _, invalid_string, _}} ->
	    {error, invalid_jid};
	US ->
	    F = fun() ->
			case gen_storage:read(LServer, {passwd, US}) of
			    [] ->
				gen_storage:write(LServer,
						  #passwd{user_host = US,
							  password = Password}),
				mnesia:dirty_update_counter(
						    reg_users_counter,
						    exmpp_jid:prep_domain(exmpp_jid:parse(Server)), 1),
				ok;
			    [_E] ->
				exists
			end
		end,
	    %% TODO: transaction return value?
	    gen_storage:transaction(LServer, passwd, F)
    end.

%% @spec () -> [{LUser, LServer}]
%%     LUser = string()
%%     LServer = string()
%% @doc Get all registered users in Mnesia.

dirty_get_registered_users() ->
    %% TODO:
    exit(not_implemented).

%% @spec (Server) -> [{LUser, LServer}]
%%     Server = string()
%%     LUser = string()
%%     LServer = string()

get_vh_registered_users(Server) ->
    LServer = exmpp_stringprep:nameprep(Server),
    lists:map(fun(#passwd{user_host = US}) ->
		      US
	      end,
	      gen_storage:dirty_select(LServer, passwd,
				       [{'=', user_host, {'_', LServer}}])).

%% @spec (Server, Opts) -> [{LUser, LServer}]
%%     Server = string()
%%     Opts = [{Opt, Val}]
%%         Opt = atom()
%%         Val = term()
%%     LUser = string()
%%     LServer = string()
%% @doc Return the registered users for the specified host.
%%
%% `Opts' can be one of the following:
%% <ul>
%% <li>`[{from, integer()}, {to, integer()}]'</li>
%% <li>`[{limit, integer()}, {offset, integer()}]'</li>
%% <li>`[{prefix, string()}]'</li>
%% <li>`[{prefix, string()}, {from, integer()}, {to, integer()}]'</li>
%% <li>`[{prefix, string()}, {limit, integer()}, {offset, integer()}]'</li>
%% </ul>

get_vh_registered_users(Server, [{from, Start}, {to, End}]) 
	when is_integer(Start) and is_integer(End) ->
    get_vh_registered_users(Server, [{limit, End-Start+1}, {offset, Start}]);

get_vh_registered_users(Server, [{limit, Limit}, {offset, Offset}]) 
	when is_integer(Limit) and is_integer(Offset) ->
    case get_vh_registered_users(Server) of
    [] ->
	[];
    Users ->
	Set = lists:keysort(1, Users),
	L = length(Set),
	Start = if Offset < 1 -> 1;
	           Offset > L -> L;
	           true -> Offset
	        end,
	lists:sublist(Set, Start, Limit)
    end;

get_vh_registered_users(Server, [{prefix, Prefix}]) 
	when is_list(Prefix) ->
    Set = [{U,S} || {U, S} <- get_vh_registered_users(Server), lists:prefix(Prefix, U)],
    lists:keysort(1, Set);

get_vh_registered_users(Server, [{prefix, Prefix}, {from, Start}, {to, End}]) 
	when is_list(Prefix) and is_integer(Start) and is_integer(End) ->
    get_vh_registered_users(Server, [{prefix, Prefix}, {limit, End-Start+1}, {offset, Start}]);

get_vh_registered_users(Server, [{prefix, Prefix}, {limit, Limit}, {offset, Offset}]) 
	when is_list(Prefix) and is_integer(Limit) and is_integer(Offset) ->
    case [{U,S} || {U, S} <- get_vh_registered_users(Server), lists:prefix(Prefix, U)] of
    [] ->
	[];
    Users ->
	Set = lists:keysort(1, Users),
	L = length(Set),
	Start = if Offset < 1 -> 1;
	           Offset > L -> L;
	           true -> Offset
	        end,
	lists:sublist(Set, Start, Limit)
    end;

get_vh_registered_users(Server, _) ->
    get_vh_registered_users(Server).

%% @spec (Server) -> Users_Number
%%     Server = string()
%%     Users_Number = integer()

get_vh_registered_users_number(Server) ->
    LServer = exmpp_jid:prep_domain(exmpp_jid:parse(Server)),
    Query = mnesia:dirty_select(
		reg_users_counter,
		[{#reg_users_counter{vhost = LServer, count = '$1'},
		  [],
		  ['$1']}]),
    case Query of
	[Count] ->
	    Count;
	_ -> 0
    end.

%% @spec (Server, [{prefix, Prefix}]) -> Users_Number
%%     Server = string()
%%     Prefix = string()
%%     Users_Number = integer()

get_vh_registered_users_number(Server, [{prefix, Prefix}]) when is_list(Prefix) ->
    Set = [{U, S} || {U, S} <- get_vh_registered_users(Server), lists:prefix(Prefix, U)],
    length(Set);
    
get_vh_registered_users_number(Server, _) ->
    get_vh_registered_users_number(Server).

%% @spec (User, Server) -> Password | false
%%     User = string()
%%     Server = string()
%%     Password = string()

get_password(User, Server) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
        case catch gen_storage:dirty_read(LServer, passwd, US) of
	    [#passwd{password = Password}] ->
		Password;
	    _ ->
		false
	end
    catch
	_ ->
	    false
    end.

%% @spec (User, Server) -> Password | nil()
%%     User = string()
%%     Server = string()
%%     Password = string()

get_password_s(User, Server) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
        case catch gen_storage:dirty_read(LServer, passwd, US) of
	    [#passwd{password = Password}] ->
		Password;
	    _ ->
		[]
	end
    catch
	_ ->
	    []
    end.

%% @spec (User, Server) -> true | false | {error, Error}
%%     User = string()
%%     Server = string()

is_user_exists(User, Server) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
        case catch gen_storage:dirty_read(LServer, {passwd, US}) of
	    [] ->
		false;
	    [_] ->
		true;
	    Other ->
		{error, Other}
	end
    catch
	_ ->
	    false
    end.

%% @spec (User, Server) -> ok
%%     User = string()
%%     Server = string()
%% @doc Remove user.
%% Note: it returns ok even if there was some problem removing the user.

remove_user(User, Server) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
	F = fun() ->
		    gen_storage:delete(LServer, {passwd, US}),
		    mnesia:dirty_update_counter(reg_users_counter,
						exmpp_jid:prep_domain(exmpp_jid:parse(Server)), -1)
	    end,
        gen_storage:transaction(LServer, passwd, F),
	ok
    catch
	_ ->
	    ok
    end.

%% @spec (User, Server, Password) -> ok | not_exists | not_allowed | bad_request
%%     User = string()
%%     Server = string()
%%     Password = string()
%% @doc Remove user if the provided password is correct.

remove_user(User, Server, Password) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
	F = fun() ->
		    case gen_storage:read(LServer, {passwd, US}) of
			[#passwd{password = Password}] ->
			    gen_storage:delete(LServer, {passwd, US}),
			    mnesia:dirty_update_counter(reg_users_counter,
							exmpp_jid:prep_domain(exmpp_jid:parse(Server)), -1),
			    ok;
			[_] ->
			    not_allowed;
			_ ->
			    not_exists
		    end
	    end,
        case gen_storage:transaction(LServer, passwd, F) of
	    {atomic, ok} ->
		ok;
	    {atomic, Res} ->
		Res
	end
    catch
	_ ->
	    bad_request
    end.

update_table(Host, mnesia) ->
    gen_storage_migration:migrate_mnesia(
      Host, passwd,
      [{passwd, [us, password],
	fun({passwd, {User, _Host}, Password}) ->
		#passwd{user_host = {User, Host},
			password = Password}
	end}]);
update_table(Host, odbc) ->
    gen_storage_migration:migrate_odbc(
      Host, [passwd],
      [{"users", ["username", "password"],
	fun(_, User, Password) ->
		#passwd{user_host = {User, Host},
			password = Password}
	end}]).
