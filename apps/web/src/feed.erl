-module(feed).
-compile(export_all).
-include_lib("n2o/include/wf.hrl").
-include_lib("kvs/include/products.hrl").
-include_lib("kvs/include/users.hrl").
-include_lib("kvs/include/feeds.hrl").
-include_lib("feed_server/include/records.hrl").
-include("records.hrl").

render_element(#feed_view{owner=undefined, title=Title, icon=Icon})->
    wf:render(dashboard:section([#h3{class=[blue], body= Title}, index:error("Anonymous users has no feeds.")], Icon));
render_element(#feed_view{icon=Icon, title=Title, feed=FeedName, owner=Owner, mode=Mode})->
    {_, Fid} = Feed = lists:keyfind(FeedName, 1, element(#iterator.feeds, Owner)),
    Entries = kvs:entries(Feed, undefined, ?PAGE_SIZE),
    Last = case Entries of []-> []; E-> lists:last(E) end,
    EsId = wf:temp_id(),
    BtnId = wf:temp_id(),
    Info = #info_more{fid=Fid, entries=EsId, toolbar=BtnId, mode=Mode},
    NoMore = length(Entries) < ?PAGE_SIZE,
    error_logger:info_msg("SETUP FEED mode: ~p feed:~p", [Mode, Feed]),
    wf:render(dashboard:section([
        #h3{class=[blue], body= Title},
        #panel{id=?ID_FEED(Fid), body=[
            #panel{id=EsId, body=[#feed_entry{entry=E, mode=Mode, controls=controls(E)} || E <- Entries]},
            #panel{id=BtnId, class=["btn-toolbar", "text-center"], body=[
            if NoMore -> []; true -> #link{class=[btn, "btn-large"], body= <<"more">>, delegate=feed, postback = {check_more, Last, Info}} end ]} ]}
    ], Icon));

render_element(#feed_entry{entry=#entry{}=E, mode=review, category=Category, controls=Controls})->
  Id = E#entry.entry_id,
  From = case kvs:get(user, E#entry.from) of {ok, User} -> User#user.display_name; {error, _} -> E#entry.from end,

  Entry = #panel{id=E#entry.entry_id, class=["row-fluid", article], body=[
    #panel{class=[span3, "article-meta"], body=[
      #h3{class=[blue], body= Category},
      #p{class=[username], body= #link{body=From, url= "/profile?id="++E#entry.from}},
      #p{class=[datestamp], body=[ #span{body= product_ui:to_date(E#entry.created)} ]},
      #p{class=[statistics], body=[
        #link{url="#",body=[ #i{class=["icon-eye-open", "icon-large"]}, #span{class=[badge, "badge-info"], body= <<"1024">>} ]},
        #link{url="#",body=[ #i{class=["icon-comments-alt", "icon-large"]}, #span{class=[badge, "badge-info"], body= <<"10">>} ]}
      ]} ]},

      #panel{id=?ID_MEDIA(Id), class=[span4, shadow], body = #entry_media{media=E#entry.media, mode=reviews}},
      #panel{class=[span5, "article-text"], body=[
        #h3{body=#span{id=?ID_TITLE(Id), class=[title], body= E#entry.title}},
        #p{id = ?ID_DESC(Id), body=product_ui:shorten(E#entry.description)},
        #panel{id=?ID_TOOL(Id), class=[more], body=Controls}
      ]}
  ]},

  element_panel:render_element(Entry);
render_element(#feed_entry{entry=#entry{}=E, mode=direct, controls=Controls})->
    User = wf:user(),
    Id = E#entry.entry_id,
  From = case kvs:get(user, E#entry.from) of {ok, U} -> U#user.display_name; {error, _} -> E#entry.from end,

  Entry = #panel{id=E#entry.entry_id, class=["row-fluid", article], body=[
    #p{body=[
      #small{body=["[", product_ui:to_date(E#entry.created), "] "]},
      #link{body= if From == User#user.email -> <<"you">>; true -> From end, url= "/profile?id="++E#entry.from},
      <<" ">>,
      wf:js_escape(wf:to_list(E#entry.title)),
      case E#entry.type of {feature, _}-> #b{body=io_lib:format(" ~p", [E#entry.type])}; _-> [] end
    ]},
    #p{body= wf:js_escape(E#entry.description)},
    #panel{id=?ID_TOOL(Id), class=[], body=Controls}
  ]},

  element_panel:render_element(Entry).

controls(#entry{type=Type} =  E) ->
    error_logger:info_msg("Type: ~p", [Type]),
    User = wf:user(),
    IsAdmin = kvs_acl:check_access(User#user.email, {feature, admin})==allow,
    case Type of {feature, _} when IsAdmin ->
    #panel{class=["btn-toolbar"], body=[
        #link{class=[btn, "btn-success"], body= <<"allow">>, postback={allow, E#entry.from, E#entry.entry_id, E#entry.type}},
        #link{class=[btn, "btn-info"], body= <<"reject">>, postback={cancel, E#entry.from, E#entry.entry_id, E#entry.type}} ]};
    direct -> [];
    reply -> [];
    product -> [
        #link{body= [#i{class=["icon-edit", "icon-large"]},<<"edit">>], postback={edit_product, E}},
        #link{body=[#i{class=["icon-remove", "icon-large"]}, <<"remove">>], postback={remove_product, E}},
        #link{body=[case Type of product -> <<"view ">>; _-> <<"read more ">> end, #i{class=["icon-double-angle-right", "icon-large"]}], postback={read, Type, E#entry.id}}];
     _ -> [#link{body=[case Type of product -> <<"view ">>; _-> <<"read more ">> end, #i{class=["icon-double-angle-right", "icon-large"]}], postback={read, Type, E#entry.id}}] end.

control_event(_, _) -> ok.
api_event(_,_,_) -> ok.

event({delivery, [_|Route], Msg}) -> process_delivery(Route, Msg);
event({allow, Whom, Eid, Feature}) ->
  error_logger:info_msg("Allow ~p : ~p", [Whom, Feature]),
  kvs_acl:define_access({user, Whom}, Feature, allow),
  User = wf:user(),

  case kvs:get(user, Whom) of {error, not_found} -> skip;
    {ok, U} ->
      ReplyRecipients = [{user, U#user.email, lists:keyfind(direct, 1, U#user.feeds)}],
      error_logger:info_msg("Reply recipients ~p", [ReplyRecipients]),
      EntryId = kvs:uuid(),
      [msg:notify([kvs_feed, RoutingType, To, entry, EntryId, add],
                  [#entry{id={EntryId, FeedId},
                          entry_id=EntryId,
                          feed_id=FeedId,
                          created = now(),
                          to = {RoutingType, To},
                          from=User#user.email,
                          type=reply,
                          media=[],
                          title= <<"Re: Feature request">>,
                          description= "You have been granted "++ io_lib:format("~p", [Feature])++"!",
                          shared=""}, skip, skip, skip, direct]) || {RoutingType, To, {_, FeedId}} <- ReplyRecipients] end,

  Recipients = [{user, User#user.email, lists:keyfind(direct,1, User#user.feeds)}],
  error_logger:info_msg("Remove recipients: ~p", [Recipients]),
  [msg:notify([kvs_feed, RouteType, To, entry, Fid, delete], [#entry{id={Eid, Feedid},entry_id=Eid}, User#user.email]) || {RouteType, To, {_, Feedid}=Fid} <- Recipients];

event({cancel, From, Eid, {feature, Feature}=Type}) ->
  User = wf:user(),
  % send message to user
  case kvs:get(user, From) of {error, not_found} -> skip;
    {ok, U} ->
      ReplyRecipients = [{user, U#user.email, lists:keyfind(direct, 1, U#user.feeds)}],
      error_logger:info_msg("Reply recipients ~p", [ReplyRecipients]),
      EntryId = kvs:uuid(),
      [msg:notify([kvs_feed, RoutingType, To, entry, EntryId, add],
                  [#entry{id={EntryId, FeedId},
                          entry_id=EntryId,
                          feed_id=FeedId,
                          created = now(),
                          to = {RoutingType, To},
                          from=User#user.email,
                          type=reply,
                          media=[],
                          title= <<"Re: Feature request">>,
                          description= "You request for "++ io_lib:format("~p", [Feature])++" has been rejected!",
                          shared=""}, skip, skip, skip, direct]) || {RoutingType, To, {_, FeedId}} <- ReplyRecipients] end,

  % delete message from feed
  Recipients = [{user, User#user.email, lists:keyfind(direct,1, User#user.feeds)}],
  error_logger:info_msg("Remove recipients: ~p", [Recipients]),
  [msg:notify([kvs_feed, RouteType, To, entry, Fid, delete], [#entry{id={Eid, Feedid}, entry_id=Eid}, User#user.email]) || {RouteType, To, {_, Feedid}=Fid} <- Recipients];

event({check_more, Start, Info = #info_more{}}) ->
  read_entries(case Start of undefined -> undefined; S -> S#entry.entry_id end, Info),
  wf:update(Info#info_more.toolbar, []);
event(Event) -> error_logger:info_msg("[notification] event: ~p", [Event]), ok.

process_delivery([_,_,entry,_,add],
                 [#entry{feed_id=Fid} = Entry, Rid, Tid, Eid, MsId,_])->
    error_logger:info_msg("[Feed-process_delivery]Add entry ~p", [Fid]),
    wf:session(medias, []),
    wf:update(MsId, []),
    wf:wire(wf:f("$('#~s').val('');", [Tid])),
    wf:wire(#jq{target=Eid, method=[html], args="''"}),
    wf:wire(wf:f("$('#~s').parent().find(':hidden').parent().html('');", [Rid])),
    error_logger:info_msg("Render entry of type: ~p", [Entry#entry.type]),
    Mode = case Entry#entry.type of 
        product -> review;
        reviews -> review;
        features-> review;
        specs   -> review;
        gallery -> review;
        videos  -> review;
        news    -> review;
        bundles -> review;
        T -> T
    end,
    error_logger:info_msg("MODE: ~p", [Mode]),
    wf:insert_top(?ID_FEED(Fid), #feed_entry{entry=Entry, mode=Mode, controls=controls(Entry)}),
    wf:wire("Holder.run();");

process_delivery([show_entry], [Entry, #info_more{} = Info]) ->
  wf:insert_bottom(Info#info_more.entries, #feed_entry{entry=Entry, mode=Info#info_more.mode, controls=controls(Entry)}),
  wf:wire("Holder.run();"),
  wf:update(Info#info_more.toolbar, #link{class=[btn, "btn-large"], body= <<"more">>, delegate=feed, postback={check_more, Entry, Info}});
process_delivery([no_more], [BtnId]) -> wf:update(BtnId, []), ok;
process_delivery(R,M) -> error_logger:info_msg("delegate to product->"),product:process_delivery(R,M).

read_entries(StartFrom, #info_more{fid=Fid}=I)->
  Feed = case StartFrom of
    undefined-> kvs:get(feed, Fid);
    S -> kvs:get(entry, {S, Fid})
  end,
  case Feed of
    {error, not_found} -> [];
    {ok, #feed{}=F} -> traverse_entries(F#feed.top, ?PAGE_SIZE, I);
    {ok, #entry{prev = E}} -> traverse_entries(E, ?PAGE_SIZE, I)
  end.

traverse_entries(undefined,_, #info_more{toolbar=BtnId}) -> self() ! {delivery, [somepath, no_more], [BtnId]}, [];
traverse_entries(_,0,_) -> [];
traverse_entries(Next, Count, I)->
  case kvs:get(entry, Next) of
    {error, not_found} -> [];
    {ok, R}->
      self() ! {delivery, [somepath, show_entry], [R, I]},
      [R | traverse_entries(R#entry.prev, Count-1, I)]
  end.