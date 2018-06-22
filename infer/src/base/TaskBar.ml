(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging

(** {2 arbitrary constants } *)

(** max size for the top bar of the multiline task bar *)
let top_bar_size_default = 100

(** do not attempt to draw the top bar of the multiline task bar unless it can be at least this big *)
let min_acceptable_progress_bar = 10

(** infer rulez *)
let job_prefix = "⊢ "

(** {2 Task bar} *)

(** state of a multi-line task bar *)
type multiline_info =
  { jobs: int  (** number of jobs running in parallel *)
  ; jobs_statuses: string Array.t
        (** array of size [jobs] with a description of what the process is doing *)
  ; jobs_start_times: Mtime.t Array.t  (** array of size [jobs] of start times for each process *)
  ; start_time: Mtime_clock.counter  (** time since the creation of the task bar *)
  ; mutable tasks_done: int
  ; mutable tasks_total: int }

type t =
  | MultiLine of multiline_info  (** interactive *)
  | NonInteractive  (** display terse progress, to use when output is redirected *)
  | Dummy  (** ignore everything *)

(** print [c] [n] times *)
let rec pp_n c oc n =
  if n > 0 then (
    Out_channel.output_char oc c ;
    pp_n c oc (n - 1) )


let draw_top_bar ~term_width ~total ~finished ~elapsed =
  let tasks_total_string = Int.to_string total in
  let bar_tasks_num_size = String.length tasks_total_string in
  let elapsed_string = F.asprintf "%a" Mtime.Span.pp elapsed in
  (* format string for the full top bar, assuming there is enough room, and number of characters
     taken by the portion of the top bar that is not the progress bar itself *)
  let top_bar_fmt, size_around_progress_bar =
    (* add pairs of a partial format string and its expected size *)
    let ( ++ ) (f1, l1) (f2, l2) = (f1 ^^ f2, l1 + l2) in
    let ( +++ ) (f1, l1) f2 = (f1 ^^ f2, l1 + (string_of_format f2 |> String.length)) in
    ("%*d", bar_tasks_num_size (* finished *)) +++ "/" ++ ("%s", bar_tasks_num_size (* total *))
    +++ " [" ++ ("%a%a", 0 (* progress bar *)) +++ "] "
    ++ ("%d%%", 3 (* "xx%", even though sometimes it's just "x%" *)) +++ " "
    ++ ( "%s"
       , max (String.length elapsed_string) 9
         (* leave some room for elapsed_string to avoid flicker. 9 characters is "XXhXXmXXs" so it
            gives some reasonable margin. *)
       )
  in
  let top_bar_size = min term_width top_bar_size_default in
  let progress_bar_size = top_bar_size - size_around_progress_bar in
  ( if progress_bar_size < min_acceptable_progress_bar then
      let s = Printf.sprintf "%d/%s %s" finished tasks_total_string elapsed_string in
      Out_channel.output_string stderr (String.prefix s term_width)
  else
    let bar_done_size = finished * progress_bar_size / total in
    Printf.eprintf top_bar_fmt bar_tasks_num_size finished tasks_total_string (pp_n '#')
      bar_done_size (pp_n '.')
      (progress_bar_size - bar_done_size)
      (finished * 100 / total)
      elapsed_string ) ;
  ANSITerminal.erase Eol ;
  Out_channel.output_string stderr "\n"


let draw_job_status ~term_width ~draw_time t ~status ~t0 =
  let length = ref 0 in
  let job_prefix_size = String.length job_prefix in
  if term_width > job_prefix_size then (
    ANSITerminal.(prerr_string [Bold; magenta]) job_prefix ;
    length := !length + job_prefix_size ) ;
  let time_width = 4 + (* actually drawing the time *) 3 (* "[] " *) in
  if draw_time && term_width > time_width + job_prefix_size then (
    let time_running = Mtime.span t0 t |> Mtime.Span.to_s in
    Printf.eprintf "[%4.1fs] " time_running ;
    length := !length + time_width ) ;
  String.prefix status (term_width - !length) |> Out_channel.output_string stderr ;
  ANSITerminal.erase Eol ;
  Out_channel.output_string stderr "\n"


let refresh_multiline task_bar =
  ANSITerminal.move_bol () ;
  let should_draw_progress_bar = task_bar.tasks_total > 0 && task_bar.tasks_done >= 0 in
  let term_width, _ = ANSITerminal.size () in
  if should_draw_progress_bar then
    draw_top_bar ~term_width ~total:task_bar.tasks_total ~finished:task_bar.tasks_done
      ~elapsed:(Mtime_clock.count task_bar.start_time) ;
  let draw_time =
    (* When there is only 1 job we are careful not to spawn processes needlessly, thus there is no
       one to refresh the task bar while the analysis is running and the time displayed will always
       be 0. Avoid confusion by not displaying the time in that case. *)
    task_bar.jobs > 1
  in
  let now = Mtime_clock.now () in
  Array.iter2_exn task_bar.jobs_statuses task_bar.jobs_start_times ~f:(fun status t0 ->
      draw_job_status ~term_width ~draw_time now ~status ~t0 ) ;
  let lines_printed =
    let progress_bar = if should_draw_progress_bar then 1 else 0 in
    task_bar.jobs + progress_bar
  in
  ANSITerminal.move_cursor 0 (-lines_printed) ;
  ()


let refresh = function MultiLine t -> refresh_multiline t | NonInteractive | Dummy -> ()

let create_multiline ~jobs =
  if Unix.(isatty stdin) && Unix.(isatty stderr) then (
    let t0 = Mtime_clock.now () in
    let task_bar =
      { jobs
      ; jobs_statuses= Array.create ~len:jobs "idle"
      ; jobs_start_times= Array.create ~len:jobs t0
      ; start_time= Mtime_clock.counter ()
      ; tasks_done= 0
      ; tasks_total= 0 }
    in
    ANSITerminal.erase Below ; MultiLine task_bar )
  else NonInteractive


let create_dummy () = Dummy

let update_status_multiline task_bar ~slot:job t0 status =
  (task_bar.jobs_statuses).(job) <- status ;
  (task_bar.jobs_start_times).(job) <- t0 ;
  ()


let update_status task_bar ~slot t0 status =
  match task_bar with
  | MultiLine t ->
      update_status_multiline t ~slot t0 status
  | NonInteractive | Dummy ->
      ()


let set_tasks_total task_bar n =
  match task_bar with
  | MultiLine multiline ->
      multiline.tasks_total <- n
  | NonInteractive | Dummy ->
      ()


let tasks_done_add task_bar n =
  match task_bar with
  | MultiLine multiline ->
      multiline.tasks_done <- multiline.tasks_done + n
  | NonInteractive ->
      L.progress "#%!"
  | Dummy ->
      ()


let tasks_done_reset task_bar =
  match task_bar with
  | MultiLine multiline ->
      multiline.tasks_done <- 0
  | NonInteractive | Dummy ->
      ()


let finish = function
  | MultiLine _ ->
      (* leave the progress bar displayed *)
      Out_channel.output_string stderr "\n" ;
      ANSITerminal.erase Below ;
      Out_channel.flush stderr
  | NonInteractive | Dummy ->
      ()


let is_interactive = function MultiLine _ -> true | NonInteractive | Dummy -> false
