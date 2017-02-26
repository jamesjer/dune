open Import
open Future

type setup =
  { build_system : Build_system.t
  ; jbuilds      : Jbuild_load.Jbuilds.t
  ; contexts     : Context.t list
  ; packages     : Package.t String_map.t
  }

let package_install_file { packages; _ } pkg =
  match String_map.find pkg packages with
  | None -> Error ()
  | Some p -> Ok (Path.relative p.path (p.name ^ ".install"))

let setup ?filter_out_optional_stanzas_with_missing_deps ?workspace () =
  let conf = Jbuild_load.load () in
  let workspace =
    match workspace with
    | Some w -> w
    | None ->
      if Sys.file_exists "jbuild-workspace" then
        Workspace.load "jbuild-workspace"
      else
        [Default]
  in
  Future.all
    (List.map workspace ~f:(function
     | Workspace.Context.Default -> Lazy.force Context.default
     | Opam { name; switch; root } ->
       Context.create_for_opam ~name ~switch ?root ()))
  >>= fun contexts ->
  Gen_rules.gen conf ~contexts
    ?filter_out_optional_stanzas_with_missing_deps
  >>= fun rules ->
  let build_system = Build_system.create ~file_tree:conf.file_tree ~rules in
  return { build_system
         ; jbuilds = conf.jbuilds
         ; contexts
         ; packages = conf.packages
         }

let external_lib_deps ?log ~packages () =
  Future.Scheduler.go ?log
    (setup () ~filter_out_optional_stanzas_with_missing_deps:false
     >>= fun ({ build_system = bs; jbuilds; contexts; _ } as setup) ->
     let install_files =
       List.map packages ~f:(fun pkg ->
         match package_install_file setup pkg with
         | Ok path -> path
         | Error () -> die "Unknown package %S" pkg)
     in
     let context =
       match List.find contexts ~f:(fun c -> c.name = "default") with
       | None -> die "You need to set a default context to use external-lib-deps"
       | Some context -> context
     in
     Jbuild_load.Jbuilds.eval ~context jbuilds
     >>| fun stanzas ->
     let internals = Jbuild_types.Stanza.lib_names stanzas in
     Path.Map.map
       (Build_system.all_lib_deps bs install_files)
       ~f:(String_map.filter ~f:(fun name _ ->
           not (String_set.mem name internals))))

let report_error ?(map_fname=fun x->x) ppf exn ~backtrace =
  match exn with
  | Loc.Error ({ start; stop }, msg) ->
    let start_c = start.pos_cnum - start.pos_bol in
    let stop_c  = stop.pos_cnum  - start.pos_bol in
    Format.fprintf ppf
      "@{<loc>File \"%s\", line %d, characters %d-%d:@}\n\
       @{<error>Error@}: %s\n"
      (map_fname start.pos_fname) start.pos_lnum start_c stop_c msg
  | Fatal_error "" -> ()
  | Fatal_error msg ->
    Format.fprintf ppf "%s\n" (String.capitalize msg)
  | Findlib.Package_not_found pkg ->
    Format.fprintf ppf "@{<error>Findlib package %S not found.@}\n" pkg
  | Code_error msg ->
    let bt = Printexc.raw_backtrace_to_string backtrace in
    Format.fprintf ppf "@{<error>Internal error, please report upstream.@}\n\
                        Description: %s\n\
                        Backtrace:\n\
                        %s" msg bt
  | _ ->
    let s = Printexc.to_string exn in
    let bt = Printexc.raw_backtrace_to_string backtrace in
    if String.is_prefix s ~prefix:"File \"" then
      Format.fprintf ppf "%s\nBacktrace:\n%s" s bt
    else
      Format.fprintf ppf "@{<error>Error@}: exception %s\nBacktrace:\n%s" s bt

let report_error ?map_fname ppf exn =
  match exn with
  | Build_system.Build_error.E err ->
    let module E = Build_system.Build_error in
    report_error ?map_fname ppf (E.exn err) ~backtrace:(E.backtrace err);
    if !Clflags.debug_dep_path then
      Format.fprintf ppf "Dependency path:\n    %s\n"
        (String.concat ~sep:"\n--> "
           (List.map (E.dependency_path err) ~f:Path.to_string))
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    report_error ?map_fname ppf exn ~backtrace

let create_log () =
  if not (Sys.file_exists "_build") then
    Unix.mkdir "_build" 0o777;
  let oc = open_out_bin "_build/log" in
  Printf.fprintf oc "# %s\n%!"
    (String.concat (List.map (Array.to_list Sys.argv) ~f:quote_for_shell) ~sep:" ");
  oc

(* Called by the script generated by ../build.ml *)
let bootstrap () =
  Ansi_color.setup_err_formatter_colors ();
  let pkg = "jbuilder" in
  let main () =
    let anon s = raise (Arg.Bad (Printf.sprintf "don't know what to do with %s\n" s)) in
    Arg.parse
      [ "-j"   , Set_int Clflags.concurrency, "JOBS concurrency"
      ; "--dev", Set Clflags.dev_mode       , " set development mode"
      ]
      anon "Usage: boot.exe [-j JOBS] [--dev]\nOptions are:";
    Future.Scheduler.go ~log:(create_log ())
      (setup ~workspace:[Default] () >>= fun { build_system = bs; _ } ->
       Build_system.do_build_exn bs [Path.(relative root) (pkg ^ ".install")])
  in
  try
    main ()
  with exn ->
    Format.eprintf "%a@?" (report_error ?map_fname:None) exn;
    exit 1
