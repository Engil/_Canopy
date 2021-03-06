open Lwt.Infix

type store_ops = {
  subkeys : string list -> string list list Lwt.t ;
  value : string list -> string option Lwt.t ;
  update : unit -> string list Lwt.t ;
  last_commit : unit -> Ptime.t Lwt.t ;
}

module Make (S: Cohttp_lwt.Server) (C: V1_LWT.CONSOLE) (Disk: V1_LWT.KV_RO)
= struct

  let read_fs fs path =
    Disk.size fs path
    >>= function
    | `Error (Disk.Unknown_key _) -> Lwt.return_none
    | `Ok size ->
      Disk.read fs path 0 (Int64.to_int size)
      >>= function
      | `Error (Disk.Unknown_key _) -> Lwt.return_none
      | `Ok bufs -> Lwt.return_some (Cstruct.copyv bufs)

  let moved_permanently uri =
    let headers = Cohttp.Header.init_with "location" (Uri.to_string uri) in
    S.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let rec dispatcher config headers console disk store atom cache uri etag updated =
    let open Canopy_utils in
    let respond_not_found () =
      S.respond_string ~headers ~status:`Not_found ~body:"Not found" ()
    in
    let respond_if_modified ~headers ~body ~updated =
      match etag with
      | Some tg when Ptime.to_rfc3339 updated = tg ->
        S.respond ~headers ~status:`Not_modified ~body:`Empty ()
      | _ ->
        S.respond_string ~headers ~status:`OK ~body ()
    in
    let respond_html ~headers ~content ~title ~updated =
      store.subkeys [] >>= fun keys ->
      let body = Canopy_templates.main ~config ~content ~title ~keys in
      let headers = html_headers headers updated in
      respond_if_modified ~headers ~body ~updated
    and respond_update = function
      | [] -> S.respond_string ~headers ~status:`OK ~body:"" ()
      | errors ->
        let body = List.fold_left (fun a b -> a ^ "\n" ^ b) "" errors in
        S.respond_string ~headers ~status:`Bad_request ~body ()
    in
    match Re_str.split (Re_str.regexp "/") (Uri.pct_decode uri) with
    | [] ->
      dispatcher config headers console disk store atom cache config.Canopy_config.index_page etag updated
    | "static"::_ ->
      begin
        read_fs disk uri >>= function
        | None -> S.respond_string ~headers ~status:`Not_found ~body:"Not found" ()
        | Some body ->
          let headers = static_headers headers uri updated in
          respond_if_modified ~headers ~body ~updated
      end
    | "atom" :: [] ->
      atom () >>= fun body ->
      store.last_commit () >>= fun updated ->
      let headers = atom_headers headers updated in
      respond_if_modified ~headers ~body ~updated
    | uri::[] when uri = config.Canopy_config.push_hook_path ->
      store.update () >>= fun l ->
      respond_update l
    | "tags"::tagname::_ -> (
      let aux _ v l =
        if Canopy_content.find_tag tagname v then (v::l) else l
      in
      let sorted = KeyHashtbl.fold aux cache [] |> List.sort Canopy_content.compare in
      match sorted with
      | [] -> respond_not_found ()
      | _ ->
        let updated = List.hd (List.rev (List.sort Ptime.compare (List.map Canopy_content.updated sorted))) in
        let content = sorted
                      |> List.map Canopy_content.to_tyxml_listing_entry
                      |> Canopy_templates.listing
        in
        respond_html ~headers ~title:config.Canopy_config.blog_name ~content ~updated
      )
     | key ->
      begin
        match KeyHashtbl.find_opt cache key with
        | None -> (
          store.subkeys key >>= fun keys ->
          if (List.length keys) = 0 then
            respond_not_found ()
          else
            let articles = List.map (KeyHashtbl.find_opt cache) keys |> list_reduce_opt in
            match articles with
            | [] -> respond_not_found ()
            | _ -> (
                let sorted = List.sort Canopy_content.compare articles in
                let updated = List.hd (List.rev (List.sort Ptime.compare (List.map Canopy_content.updated articles))) in
                let content = sorted
                              |> List.map Canopy_content.to_tyxml_listing_entry
                              |> Canopy_templates.listing
                in
                respond_html ~headers ~title:config.Canopy_config.blog_name ~content ~updated
              ))
        | Some article ->
          let title, content = Canopy_content.to_tyxml article in
          let updated = Canopy_content.updated article in
          respond_html ~headers ~title ~content ~updated
      end

    let create console dispatch =
      let conn_closed (_, conn_id) =
        let cid = Cohttp.Connection.to_string conn_id in
        C.log console (Printf.sprintf "conn %s closed" cid)
      in
      let callback = match dispatch with
        | `Redirect fn ->
          (fun _ request _ ->
             let req = Cohttp.Request.uri request in
             let uri = fn req in
             C.log_s console (Printf.sprintf "redirecting to %s" (Uri.to_string uri)) >>= fun () ->
             moved_permanently uri)
        | `Dispatch (config, headers, disk, store, atom, content, time) ->
          (fun _ request _ ->
             let uri = Cohttp.Request.uri request in
             let etag = Cohttp.Header.get Cohttp.Request.(request.headers) "if-none-match" in
             C.log_s console (Printf.sprintf "request %s" (Uri.to_string uri)) >>= fun () ->
             dispatcher config headers console disk store atom content (Uri.path uri) etag time)
      in
      S.make ~callback ~conn_closed ()


end
