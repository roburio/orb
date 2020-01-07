(**************************************************************************)
(*                                                                        *)
(*    Copyright 2019 OCamlPro                                             *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

(* TODO record missing inputs:
   - host system packages (that are relevant)
   - cpu features etc. for cpuid
*)

open OpamStateTypes

(** Utils *)
let log fmt =
  let orb = OpamConsole.(colorise `bold "[ORB]" |> colorise `cyan) in
  OpamConsole.msg ("%s "^^fmt^^"\n") orb

let read_file file =
  let filename = OpamFilename.to_string file in
  let ic =
    OpamFilename.(mkdir (dirname file));
    try open_in_bin filename with Sys_error _ -> raise (OpamSystem.File_not_found filename)
  in
  try
    let len = in_channel_length ic in
    let data = really_input_string ic len in
    close_in ic;
    data
  with e ->
    OpamStd.Exn.finalise e @@ fun () ->
    close_in ic

let write_file file value =
  let filename = OpamFilename.to_string file in
  let oc =
    OpamFilename.(mkdir (dirname file));
    try open_out_bin filename with Sys_error _ -> raise (OpamSystem.File_not_found filename)
  in
  try
    Unix.lockf (Unix.descr_of_out_channel oc) Unix.F_LOCK 0;
    output_string oc value;
    close_out oc;
  with e ->
    OpamStd.Exn.finalise e @@ fun () ->
    close_out oc; OpamFilename.remove file

let remove_switch switch =
  OpamGlobalState.with_ `Lock_write @@ fun gt ->
  OpamGlobalState.drop @@
  OpamSwitchCommand.remove ~confirm:false gt switch;
  log "Switch %s removed"
    (OpamSwitch.to_string switch |> OpamConsole.colorise `blue)

let clean_switch = ref None

let cleanup () =
  log "cleaning up";
  match !clean_switch with
  | None -> ()
  | Some switch ->
    remove_switch switch;
    OpamFilename.rmdir
      (OpamFilename.Dir.of_string (OpamSwitch.to_string switch));
    clean_switch := None

let exit_error reason fmt =
  cleanup ();
  OpamConsole.error_and_exit reason fmt

let get2 = function  s1::s2::[]-> s1, s2 | _ -> assert false

let list_init len f =
  let rec init_aux i n f =
    if i >= n then []
    else
      let r = f i in
      r :: init_aux (i+1) n f
  in
  init_aux 0 len f

let seq l f =
  List.iter f l

let fork lst f =
  let pids =
    List.map (fun arg -> (* to be sure to have at least 1s of delay in tms *)
        Unix.sleep 1;
        match Unix.fork () with
        | 0 -> (try f arg with OpamStd.Sys.Exit n -> exit n); exit 255
        | pid -> pid) lst
    |> OpamStd.IntSet.of_list
  in
  let w, err =
    List.fold_left (fun (w,err) (p,e) ->
        let w = p::w in
        if e = Unix.WEXITED 255 then w, err else w, e::err)
      ([],[])
      (list_init (OpamStd.IntSet.cardinal pids) (fun _ -> Unix.wait ()))
  in
  let w = OpamStd.IntSet.of_list w in
  let remaining = OpamStd.IntSet.Op.(pids -- w) in
  if not (OpamStd.IntSet.is_empty remaining) then
    exit_error `Not_found "Remaining pids %s"
      (OpamStd.IntSet.to_string remaining);
  if err <> [] then
    exit_error `False
      "Some subprocesses ended with a non-zero code: %s"
      (OpamStd.Format.pretty_list (List.map (function
           | Unix.WEXITED e -> Printf.sprintf "exit %d" e
           | Unix.WSIGNALED e -> Printf.sprintf "signal %d" e
           | Unix.WSTOPPED e -> Printf.sprintf "stop %d" e) err))

let drop_states ?gt ?rt ?st () =
  OpamStd.Option.iter OpamSwitchState.drop st;
  OpamStd.Option.iter OpamRepositoryState.drop rt;
  OpamStd.Option.iter OpamGlobalState.drop gt

let dot_switch = ".opam-switch"
let dot_hash = ".build-hashes"
let dot_env = ".build-environment"
let dot_build = ".build"
let dot_diffoscope = ".diffoscope"

let switch_filename dir name =
  let fn = Printf.sprintf "%s/%s%s" dir name dot_switch in
  OpamFile.make (OpamFilename.of_string fn)

let convert_date x = string_of_int (int_of_float x)

let custom_env = [
  "OS", OpamSysPoll.os ();
  "OS_DISTRIBUTION", OpamSysPoll.os_distribution ();
  "OS_VERSION", OpamSysPoll.os_version ();
  "OS_FAMILY", OpamSysPoll.os_family ();
]

let create_env epoch dir =
  [
    "SWITCH_PATH", dir;
    "SOURCE_DATE_EPOCH", convert_date epoch;
    "BUILD_DATE", convert_date (Unix.time ());
  ] @
  List.fold_left
    (fun acc (k, v) -> match v with None -> acc | Some v -> (k,v)::acc)
    [] custom_env

let env_to_string env =
  String.concat "\n" ("" :: List.map (fun (k, v) -> k ^ "=" ^ v) env)

let env_of_string str =
  let lines = String.split_on_char '\n' str in
  List.fold_left (fun acc line ->
      match String.split_on_char '=' line with
      | [ key ; value ] -> (key, value) :: acc
      | _ -> log "bad environment %s" line ; acc)
    [] lines

let env_matches env =
  (* TODO may relax e.g. OS_VERSION is DISTRIBUTION is detailed enough *)
  let opt_compare key v =
    match v, List.assoc_opt key env with
    | None, _ -> log "key %s not available" key ; true
    | _, None -> log "key %s not found in environment" key ; true
    | Some v, Some v' -> String.equal v v'
  in
  List.for_all (fun (k, v) -> opt_compare k v) custom_env

let add_env _switch epoch gt st =
  let env = OpamFile.Switch_config.env st.OpamStateTypes.switch_config in
  let source_date_epoch =
    "SOURCE_DATE_EPOCH", OpamParserTypes.Eq, convert_date epoch,
    Some "Reproducible builds date" ;
  in
  (*  let value = target ^ "=" ^ OpamSwitch.to_string switch in
      log "BPPM is %s!" (OpamConsole.colorise `green value);
      let prefix_map =
      "BUILD_PATH_PREFIX_MAP", OpamParserTypes.Eq,
      value, Some "Build path prefix map"
      in *)
  let to_add =
    List.fold_left (fun swc v ->
        let s,_,_,_ = v in
        match OpamStd.List.find_opt (fun (s',_,_,_) -> s = s') env with
        | Some _ -> swc
        | None -> v::swc) [] [ (* prefix_map ; *) source_date_epoch ]
  in
  log "adding to environment (time %s): %s"
    (convert_date (Unix.time ()))
    (env_to_string (List.map (fun (k, _, v, _) -> (k, v)) to_add));
  let switch_config =
      OpamFile.Switch_config.with_env (to_add @ env) st.switch_config
  in
  let st = { st with switch_config } in
  let switch = st.switch in
  OpamFile.Switch_config.write
    (OpamPath.Switch.switch_config gt.OpamStateTypes.root switch) st.switch_config;
  st

(** Steps *)
let import_switch epoch switch export =
  OpamGlobalState.with_ `Lock_write @@ fun gt ->
  OpamRepositoryState.with_ `Lock_none gt @@ fun rt ->
  let gt, st =
    OpamSwitchCommand.install gt ~rt ~local_compiler:true
      ~packages:[] ~update_config:false switch
  in
  log "Switch %s created!"
    (OpamConsole.colorise `green (OpamSwitch.to_string switch));
  clean_switch := Some switch;
  let st = add_env switch epoch gt st in
  log "now importing switch";
  let st = OpamSwitchCommand.import st export in
  log "Switch %s imported!"
    (OpamConsole.colorise `green (OpamSwitch.to_string switch));
  let roots = st.installed_roots in
  drop_states ~gt ~rt ~st ();
  roots

let install_switch epoch ?repos compiler_pin compiler_version switch =
  OpamGlobalState.with_ `Lock_write @@ fun gt ->
  OpamRepositoryState.with_ `Lock_none gt @@ fun rt ->
  let gt, st =
    OpamSwitchCommand.install gt ~rt ~local_compiler:true ?repos
      ~packages:[] ~update_config:false switch
  in
  log "Switch %s created!"
    (OpamConsole.colorise `green (OpamSwitch.to_string switch));
  let st = match compiler_pin, compiler_version with
    | None, None -> st
    | Some path, None ->
      let src = `Source (OpamUrl.parse ("git+file://" ^ path)) in
      let pkg = OpamPackage.Name.of_string "ocaml-variants" in
      let st = OpamClient.PIN.pin ~action:false st pkg src in
      log "Pinned compiler to %s" path;
      st
    | None, Some v ->
      let version = OpamPackage.Version.of_string v in
      let pkg =
        OpamPackage.Name.of_string
          (if OpamStd.String.contains_char v '+' then "ocaml-variants" else "ocaml")
      in
      let st = OpamClient.PIN.pin ~action:false st pkg (`Version version) in
      log "Pinned compiler to %s.%s" (OpamPackage.Version.to_string version)
        (OpamPackage.Version.to_string version);
      st
    | Some _, Some _ ->
      exit_error `Bad_arguments
        "Both compiler-pin and compiler provided, choose one.";
  in
  let st = add_env switch epoch gt st in
  drop_states ~gt ~rt ~st ()

let update_switch_env epoch switch =
  OpamGlobalState.with_ `Lock_write @@ fun gt ->
  if not (OpamGlobalState.switch_exists gt switch) then
    (drop_states ~gt ();
     exit_error `Not_found "Switch %s doesn't exist"
       (OpamSwitch.to_string switch |> OpamConsole.colorise `underline))
  else
    OpamRepositoryState.with_ `Lock_none gt @@ fun rt ->
    OpamSwitchState.with_ `Lock_write ~rt ~switch gt @@ fun st ->
    let st = add_env switch epoch gt st in
    drop_states ~gt ~rt ~st ()

let install switch atoms_or_locals =
  log "Install start";
  OpamGlobalState.with_ `Lock_none @@ fun gt ->
  OpamRepositoryState.with_ `Lock_none gt @@ fun rt ->
  OpamSwitchState.with_ `Lock_write ~rt ~switch gt @@ fun st ->
  let st, atoms =
    OpamAuxCommands.autopin st ~simulate:true atoms_or_locals
  in
  (* Remove already installed ones *)
  let st =
    let installed =
      OpamPackage.Name.Set.Op.(
        OpamPackage.names_of_packages
          (OpamFormula.packages_of_atoms st.packages atoms)
        %% OpamPackage.names_of_packages st.installed)
    in
    if OpamPackage.Name.Set.is_empty installed then st else
      (log "Remove previously installed packages: %s"
         (OpamPackage.Name.Set.to_string installed);
       OpamClient.remove st ~autoremove:false ~force:false atoms)
  in
  log "Install %s" (OpamFormula.string_of_atoms atoms);
  let st = OpamClient.install st atoms in
  drop_states ~gt ~rt ~st ()

let tracking_maps switch atoms_or_locals =
  OpamGlobalState.with_ `Lock_none @@ fun gt ->
  OpamSwitchState.with_ `Lock_none ~switch gt @@ fun st ->
  log "tracking map got locks";
  let st, packages =
    let p =
      let _, atoms = OpamAuxCommands.resolve_locals atoms_or_locals in
      log "tracking map %d atoms (package set %d - %d packages)"
        (List.length atoms)
        (OpamPackage.Set.cardinal st.installed)
        (OpamPackage.Set.cardinal st.packages);
      let packages =  OpamFormula.packages_of_atoms st.installed atoms in
      log "tracking map %d packages" (OpamPackage.Set.cardinal packages);
      let ifer = OpamPackage.Set.inter st.installed packages in
      log "tracking map %d packages later" (OpamPackage.Set.cardinal ifer);
      ifer
    in
    st, p
  in
  log "tracking map got st and %d packages (%d atoms_or_locals)"
    (OpamPackage.Set.cardinal packages) (List.length atoms_or_locals);
  let tr =
    OpamPackage.Set.fold (fun pkg acc ->
        let name = OpamPackage.name pkg in
        let changes_file =
          OpamPath.Switch.changes gt.root switch name
          |> OpamFile.Changes.read
        in
        OpamPackage.Map.add pkg changes_file acc)
      packages OpamPackage.Map.empty
  in
  log "tracking map got tr, dropping states";
  drop_states ~gt ~st ();
  tr

let read_tracking_map ?(generation = 0) dir package =
  let nam = Printf.sprintf "%s/%s%s.%d" dir package dot_hash generation in
  OpamFile.Changes.read_opt (OpamFile.make (OpamFilename.of_string nam))

type diff =
  | Both of OpamDirTrack.change * OpamDirTrack.change
  | First of OpamDirTrack.change
  | Second of OpamDirTrack.change

let string_of_diff = function
  | Both (c,c') ->
    OpamDirTrack.string_of_change c ^ " / " ^ OpamDirTrack.string_of_change c'
  | First c -> "๛ / " ^ OpamDirTrack.string_of_change c
  | Second c -> OpamDirTrack.string_of_change c ^ " / ๛"

(* Calculate the final diff map *)
let diff_map track1 track2 =
  OpamPackage.Map.fold (fun pkg sm1 map ->
      log "diff map folding %s" (OpamPackage.Name.to_string pkg.OpamPackage.name);
      let file_map =
        match OpamPackage.Map.find_opt pkg track2 with
        | Some sm2 ->
          let diff, rest =
            OpamStd.String.Map.fold (fun file d1 (diff, sm2) ->
                match OpamStd.String.Map.find_opt file sm2 with
                | Some d2 ->
                  log "diff map for %s found" file;
                  let diff =
                    if d1 <> d2 then begin
                      log "d1 and d2 mismatch";
                      OpamStd.String.Map.add file (Both (d1,d2)) diff
                    end else diff
                  in
                  diff,
                  OpamStd.String.Map.remove file sm2
                | None ->
                  log "diff map for %s not found" file;
                  OpamStd.String.Map.add file (First d1) diff, sm2)
              sm1 (OpamStd.String.Map.empty, sm2)
          in
          if OpamStd.String.Map.is_empty rest then begin
            log "diff map rest empty";
            diff
          end else begin
            log "diff map union";
            OpamStd.String.Map.union (fun _ _ -> assert false) diff
              (OpamStd.String.Map.map (fun d2 -> Second d2) rest)
          end
        | None ->
          log "diff map no file map in track2";
          OpamStd.String.Map.empty
      in
      if OpamStd.String.Map.is_empty file_map then map
      else OpamPackage.Map.add pkg file_map map
    ) track1 OpamPackage.Map.empty

let output_buildinfo_and_env dir name map env =
  let filename post =
    let rec fn n =
      let filename = post ^ "." ^ string_of_int n in
      let file = Filename.concat dir filename in
      if Sys.file_exists file then fn (succ n) else filename, n
    in
    let file, gen = fn 0 in
    OpamFilename.(create (Dir.of_string dir) (Base.of_string file)), gen
  in
  OpamPackage.Map.iter (fun pkg map ->
      let value = OpamFile.Changes.write_to_string map in
      let fn, _ = filename (OpamPackage.Name.to_string pkg.name ^ dot_hash) in
      log "writing %s" (OpamFilename.to_string fn);
      write_file fn value)
    map;
  let fn, gen = filename (name ^ dot_env) in
  write_file fn (env_to_string env);
  gen

let find_build_dir generation dir =
  let dir = Printf.sprintf "%s/%d%s" dir generation dot_build in
  if Sys.file_exists dir then Some dir else None

let copy_build_dir dir generation switch =
  let target = Printf.sprintf "%s/%d%s" dir generation dot_build in
  log "preserving build dir in %s" target;
  OpamFilename.copy_dir
    ~src:(OpamFilename.Dir.of_string (OpamSwitch.to_string switch))
    ~dst:(OpamFilename.Dir.of_string target);
  target

let export switch dir name =
  OpamGlobalState.with_ `Lock_none @@ fun gt ->
  OpamRepositoryState.with_ `Lock_none gt @@ fun rt ->
  let switch_out = switch_filename dir name in
  OpamSwitchCommand.export rt ~full:true ~switch (Some switch_out);
  drop_states ~gt ~rt ()

let generate_diffs root1 root2 final_map dir =
  let dir = OpamFilename.Dir.of_string dir
  and root1 = OpamFilename.Dir.of_string (root1 ^ "/_opam")
  and root2 = OpamFilename.Dir.of_string (root2 ^ "/_opam")
  in
  let open OpamFilename.Op in
  OpamFilename.mkdir dir;
  OpamPackage.Map.iter (fun pkg _ ->
      OpamFilename.mkdir (dir / OpamPackage.to_string pkg)) final_map;
  let full =
    let copy pkg file num =
      let root, suffix =
        match num with
        | `fst -> root1, "orb_fst"
        | `snd -> root2, "orb_snd"
      in
      OpamFilename.copy ~src:(root // file)
        ~dst:(OpamFilename.add_extension (dir / pkg // file) suffix)
    in
    let make_cmd pkg file =
      OpamSystem.make_command "diffoscope"
        [OpamFilename.to_string (root1 // file);
         OpamFilename.to_string (root2 // file);
         "--text"; (OpamFilename.to_string (dir / pkg // (file ^ ".diff")))]
    in
    OpamPackage.Map.fold (fun pkg tr acc ->
        let spkg = OpamPackage.to_string pkg in
        OpamStd.String.Map.fold (fun file diff acc ->
            (diff, (copy spkg file), (make_cmd spkg file)) :: acc) tr acc)
      final_map []
  in
  (* Here we use opam parallelism *)
  let open OpamProcess.Job.Op in
  let command (diff, copy, cmd) =
    match diff with
    | Both (_, _) ->
      copy `fst;
      copy `snd;
      cmd @@> fun _ -> Done ()
    | First _ -> copy `fst; Done ()
    | Second _ -> copy `snd; Done ()
  in
  try
    OpamParallel.iter ~jobs:OpamStateConfig.(Lazy.force !r.jobs) ~command full
  with OpamParallel.Errors (_, err, can)->
    OpamConsole.error "Some jobs failed:\n%s\nand other canceled:\n%s\n"
      (OpamStd.Format.itemize (fun (i,e) ->
           let _, _, cmd = List.nth full i in
           Printf.sprintf "%s : %s"
             (OpamProcess.string_of_command cmd) (Printexc.to_string e))
          err)
      (OpamStd.Format.itemize (fun i ->
           let _, _, cmd = List.nth full i in
           OpamProcess.string_of_command cmd) can)

let common_start global_options build_options diffoscope =
  if diffoscope && OpamSystem.resolve_command "diffoscope" = None then
    exit_error `Not_found "diffoscope not found";
  let root = OpamStateConfig.(!r.root_dir) in
  let config_f = OpamPath.config root in
  let already_init = OpamFile.exists config_f in
  OpamArg.apply_global_options global_options;
  OpamArg.apply_build_options build_options;
  if not already_init then
    exit_error `False "orb needs an already initialised opam";
  OpamCoreConfig.update ~precise_tracking:true ~answer:(Some true) ();
  OpamStd.Sys.at_exit cleanup

let compare_builds tracking_map tracking_map' dir build1st build2nd diffoscope =
  let final_map = diff_map tracking_map tracking_map' in
  if OpamPackage.Map.is_empty final_map then
    log "%s" (OpamConsole.colorise `green "It is reproducible!!!")
  else
    (log "There are some %s\n%s"
       (OpamConsole.colorise `red "mismatching hashes")
       (OpamPackage.Map.to_string
          (OpamStd.String.Map.to_string string_of_diff) final_map);
     if diffoscope then
       match build1st with
       | None -> log "no previous build dir available, couldn't run diffoscope"
       | Some build1 -> generate_diffs build1 build2nd final_map dir)

let project_name_from_arg = function
  | `Atom (name, _) :: _ -> OpamPackage.Name.to_string name
  | `Dirname dir :: _ -> OpamFilename.Dir.to_string dir
  | `Filename file :: _ -> OpamFilename.to_string file
  | _ -> invalid_arg "empty atoms_or_locals"

let project_name_from_dir dir = (* the first <name>.opam-switch *)
  match
    List.find_opt (fun t -> OpamFilename.check_suffix t dot_switch)
      (OpamFilename.files (OpamFilename.Dir.of_string dir))
  with
  | None -> failwith "couldn't find switch"
  | Some t -> OpamFilename.(Base.to_string (basename (chop_extension t)))

let find_env dir =
  let envs =
    List.filter
      (fun t -> OpamFilename.(check_suffix (chop_extension t) dot_env))
      (OpamFilename.files (OpamFilename.Dir.of_string dir))
  in
  let rec good_env = function
    | [] -> failwith "no environment found"
    | file :: files ->
      let env = env_of_string (read_file file) in
      if env_matches env then begin
        log "environment %s matches, using it" (OpamFilename.to_string file);
        env, file
      end else begin
        log "environment %s does not match" (OpamFilename.to_string file);
        good_env files
      end
  in
  let env, filename = good_env envs in
  let name = OpamFilename.(Base.to_string (basename (chop_extension (chop_extension filename)))) in
  let generation =
    match OpamStd.String.rcut_at (OpamFilename.to_string filename) '.' with
    | None -> log "no generation found in %s" (OpamFilename.to_string filename); 0
    | Some (_, x) ->
      log "generation %s" x;
      int_of_string x
  in
  name, generation, env

let rebuild ~sw ~bidir ~name epoch ~keep_build =
  let switch = OpamSwitch.of_string sw in
  let switch_in = switch_filename bidir name in
  let packages = import_switch epoch switch (Some switch_in) in
  let atoms_or_locals =
    List.map (fun a -> `Atom (a.OpamPackage.name, None))
      (OpamPackage.Set.elements packages)
  in
  log "switch imported (installed stuff)";
  let tracking_map = tracking_maps switch atoms_or_locals in
  log "tracking map";
  log "%s" (OpamConsole.colorise `green "BUILD INFO");
  let env = create_env epoch sw in
  let generation = output_buildinfo_and_env bidir name tracking_map env in
  let build2nd = if keep_build then copy_build_dir bidir generation switch else sw in
  log "wrote tracking map";
  tracking_map, build2nd, generation, packages

(* Main function *)
let build global_options build_options diffoscope keep_build twice compiler_pin compiler switch
    repos atoms_or_locals =
  if atoms_or_locals = [] then
    exit_error `Bad_arguments
      "I can't check reproductibility of nothing, by definition, it is";
  common_start global_options build_options diffoscope;
  (match compiler_pin, compiler, switch with
   | None, None, None -> OpamStateConfig.update ~unlock_base:true ();
   | _ -> ());
  let name = project_name_from_arg atoms_or_locals in
  let bidir = OpamSystem.mk_temp_dir ~prefix:("bi-" ^ name) () in
  let sw = bidir ^ "/build" in
  let switch' = OpamSwitch.of_string sw in
  if switch = None then clean_switch := Some switch';
  let epoch = Unix.time () in
  (match switch with
   | None -> install_switch epoch ?repos compiler_pin compiler switch'
   | Some _ -> update_switch_env epoch switch');
  install switch' atoms_or_locals;
  log "installed";
  let tracking_map = tracking_maps switch' atoms_or_locals in
  log "%s" (OpamConsole.colorise `green "BUILD INFO");
  let env = create_env epoch (OpamSwitch.to_string switch') in
  let generation = output_buildinfo_and_env bidir name tracking_map env in
  (* switch export - make a full one *)
  export switch' bidir name;
  let build1st =
    if twice || keep_build
    then Some (copy_build_dir bidir generation switch')
    else None
  in
  cleanup ();
  if twice then
    let tracking_map', build2nd, my_gen, _ = rebuild ~sw ~bidir ~name epoch ~keep_build:true in
    let dir = Printf.sprintf "%s/%d-%d%s" bidir generation my_gen dot_diffoscope in
    compare_builds tracking_map tracking_map' dir  build1st build2nd diffoscope

let rebuild global_options build_options diffoscope keep_build dir =
  if dir = "" then failwith "require build info directory" else begin
    common_start global_options build_options diffoscope;
    OpamStateConfig.update ~unlock_base:true ();
    let name, generation, env = find_env dir in
    let sw = List.assoc "SWITCH_PATH" env in
    let epoch = float_of_string @@ List.assoc "SOURCE_DATE_EPOCH" env in
    let tracking_map_2nd, build2nd, my_gen, packages =
      rebuild ~sw ~bidir:dir ~name epoch ~keep_build
    in
    let tracking_map_1st = OpamPackage.Set.fold (fun pkg acc ->
        match read_tracking_map ~generation dir (OpamPackage.Name.to_string pkg.OpamPackage.name) with
        | None -> log "no tracking map for %s found" (OpamPackage.Name.to_string pkg.OpamPackage.name); acc
        | Some tm -> OpamPackage.Map.add pkg tm acc)
        packages OpamPackage.Map.empty
    in
    let build1st = find_build_dir generation dir in
    log "comparing with old build dir %s" (match build1st with None -> "no" | Some x -> x);
    let dir = Printf.sprintf "%s/%d-%d%s" dir generation my_gen dot_diffoscope in
    compare_builds tracking_map_1st tracking_map_2nd dir build1st build2nd diffoscope
  end

(** CLI *)
open Cmdliner
open OpamArg

let diffoscope = mk_flag ["diffoscope"] "use diffoscope to generate a report"

let keep_build =
  mk_flag ["keep-build"] "keep built temporary products"

let build_cmd =
  let doc = "Build opam packages and output build information for rebuilding" in
  let man = [
    `S "DESCRIPTION";
    `P "$(b,build) is a tool to check the reproducibility of opam package builds. \
        It relies on an already installed opam, and creates required build \
        information for reproducing the same output.";
    `S "ARGUMENTS";
    `S "OPTIONS";
    `S OpamArg.build_option_section;
  ]
  in
  let twice =
    mk_flag ["twice"] "build twice, output differences (implies --keep-build)"
  in
  let compiler_pin =
    mk_opt [ "compiler-pin" ] "[DIR]"
      "use the compiler in [DIR] for the temporary switch"
      Arg.(some string) None
  in
  let compiler =
    mk_opt [ "compiler" ] "[VERSION]"
      "use the compiler [VERSION] for the temporary switch"
      Arg.(some string) None
  in
  let use_switch =
    mk_opt ["use-switch"] "SWITCH"
      "use the switch instead of a newly generated ones"
      Arg.(some string) None
  in
  let repos =
    mk_opt ["repos"] "REPOS"
      "Include only packages that took their origin from one of the given \
       repositories."
      Arg.(some & list & OpamArg.repository_name) None
  in
  Term.((const build $ global_options $ build_options
         $ diffoscope $ keep_build $ twice $ compiler_pin $ compiler $ use_switch
         $ repos $ atom_or_local_list)),
  Term.info "build" ~man ~doc

let rebuild_cmd =
  let doc = "Rebuild opam packages based on build information" in
  let man = [
    `S "DESCRIPTION";
    `P "$(b,rebuild) is a tool to rebuild an opam package using an exported \
        opam switch, a build environment, and reported build hashes. If an \
        existing build environment matches the host operating system, the \
        hashes of the installed files of all roots in the export are compared \
        against the previous build. If the build directory is kept, diffoscope \
        can be used to make the differences human readable.";
    `S "ARGUMENTS";
    `S "OPTIONS";
    `S OpamArg.build_option_section;
  ]
  in
  let build_info =
    let doc = "use build information in the provided directory" in
    Arg.(value & pos 0 string "" & info [] ~doc ~docv:"DIR")
  in
  Term.((const rebuild $ global_options $ build_options $ diffoscope $ keep_build $ build_info)),
  Term.info "rebuild" ~man ~doc

let help man_format cmds = function
  | None -> `Help (`Pager, None)
  | Some t when List.mem t cmds -> `Help (man_format, Some t)
  | Some _ -> List.iter print_endline cmds; `Ok ()

let help_cmd =
  let topic =
    let doc = "The topic to get help on. `topics' lists the topics." in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
  in
  let doc = "display help about vmmc" in
  let man =
    [`S "DESCRIPTION";
     `P "Prints help about orb commands and subcommands"]
  in
  Term.(ret (const help $ Term.man_format $ Term.choice_names $ topic)),
  Term.info "help" ~doc ~man

let default_cmd =
  let doc = "OPAM reproducible builder" in
  let man = [
    `S "DESCRIPTION" ;
    `P "$(tname) builds opam packages, checking for reproducibility." ;
  ] in
  Term.(ret (const help $ Term.man_format $ Term.choice_names $ Term.pure None)),
  Term.info "orb" ~version:"%%VERSION%%" ~doc ~man

let cmds = [ build_cmd ; rebuild_cmd ]

let () =
  Orb_stub.main ();
  let buff = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buff in
  match Term.eval_choice default_cmd cmds ~err:fmt ~catch:true with
  | `Error (`Term | `Parse) ->
    Format.pp_print_flush fmt ();
    OpamConsole.msg "%s" (Buffer.contents buff)
  | _ -> ()
