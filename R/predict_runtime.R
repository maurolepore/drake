#' @title Predict the elapsed runtime of the next call to `make()`
#'   for non-staged parallel backends.
#' @description Take the past recorded runtimes times from
#'   [build_times()] and use them to predict how the targets
#'   will be distributed among the available workers in the
#'   next [make()]. Then, predict the overall runtime to be the
#'   runtime of the slowest (busiest) workers.
#'   Predictions only include the time it takes to run the targets,
#'   not overhead/preprocessing from `drake` itself.
#' @export
#' @return Predicted total runtime of the next call to [make()].
#' @inheritParams predict_workers
#' @seealso [predict_workers()], [build_times()], [make()]
#' @examples
#' \dontrun{
#' isolate_example("Quarantine side effects.", {
#' if (suppressWarnings(require("knitr"))) {
#' load_mtcars_example() # Get the code with drake_example("mtcars").
#' make(my_plan) # Run the project, build the targets.
#' config <- drake_config(my_plan)
#' known_times <- rep(7200, nrow(my_plan))
#' names(known_times) <- my_plan$target
#' known_times
#' # Predict the runtime
#' if (requireNamespace("lubridate", quietly = TRUE)) {
#' predict_runtime(
#'   config,
#'   jobs = 7,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' predict_runtime(
#'   config,
#'   jobs = 8,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' balance <- predict_workers(
#'   config,
#'   jobs = 7,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' balance
#' }
#' }
#' })
#' }
predict_runtime <- function(
  config,
  targets = NULL,
  from_scratch = FALSE,
  targets_only = NULL,
  jobs = 1,
  known_times = numeric(0),
  default_time = 0,
  warn = TRUE
) {
  log_msg("begin predict_runtime()", config = config)
  on.exit(log_msg("end predict_runtime()", config = config), add = TRUE)
  worker_prediction_info(
    config = config,
    targets = targets,
    from_scratch = from_scratch,
    targets_only = targets_only,
    jobs = jobs,
    known_times = known_times,
    default_time = default_time,
    warn = warn
  )$time
}

#' @title Predict the load balancing of the next call to `make()`
#'   for non-staged parallel backends.
#' @description Take the past recorded runtimes times from
#'   [build_times()] and use them to predict how the targets
#'   will be distributed among the available workers in the
#'   next [make()].
#'   Predictions only include the time it takes to run the targets,
#'   not overhead/preprocessing from `drake` itself.
#' @export
#' @seealso [predict_runtime()], [build_times()], [make()]
#' @examples
#' \dontrun{
#' isolate_example("Quarantine side effects.", {
#' if (suppressWarnings(require("knitr"))) {
#' load_mtcars_example() # Get the code with drake_example("mtcars").
#' make(my_plan) # Run the project, build the targets.
#' config <- drake_config(my_plan)
#' known_times <- rep(7200, nrow(my_plan))
#' names(known_times) <- my_plan$target
#' known_times
#' # Predict the runtime
#' if (requireNamespace("lubridate", quietly = TRUE)) {
#' predict_runtime(
#'   config = config,
#'   jobs = 7,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' predict_runtime(
#'   config,
#'   jobs = 8,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' balance <- predict_workers(
#'   config,
#'   jobs = 7,
#'   from_scratch = TRUE,
#'   known_times = known_times
#' )
#' balance
#' }
#' }
#' })
#' }
#' @return A data frame showing one likely arrangement
#'   of targets assigned to parallel workers.
#' @param config Optional internal runtime parameter list of
#'   produced by both [make()] and
#'   [drake_config()].
#' @param targets Character vector, names of targets.
#'   Predict the runtime of building these targets
#'   plus dependencies.
#'   Defaults to all targets.
#' @param from_scratch Logical, whether to predict a
#'   [make()] build from scratch or to
#'   take into account the fact that some targets may be
#'   already up to date and therefore skipped.
#' @param targets_only Deprecated.
#' @param jobs The `jobs` argument of your next planned
#'   `make()`. How many targets to do you plan
#'   to have running simultaneously?
#' @param known_times A named numeric vector with targets/imports
#'   as names and values as hypothetical runtimes in seconds.
#'   Use this argument to overwrite any of the existing build times
#'   or the `default_time`.
#' @param default_time Number of seconds to assume for any
#'   target or import with no recorded runtime (from [build_times()])
#'   or anything in `known_times`.
#' @param warn Logical, whether to warn the user about
#'   any targets with no available runtime, either in
#'   `known_times` or [build_times()]. The times for these
#'   targets default to `default_time`.
predict_workers <- function(
  config,
  targets = NULL,
  from_scratch = FALSE,
  targets_only = NULL,
  jobs = 1,
  known_times = numeric(0),
  default_time = 0,
  warn = TRUE
) {
  log_msg("begin predict_workers()", config = config)
  on.exit(log_msg("end predict_workers()", config = config), add = TRUE)
  worker_prediction_info(
    config,
    targets = targets,
    from_scratch = from_scratch,
    targets_only = targets_only,
    jobs = jobs,
    known_times = known_times,
    default_time = default_time,
    warn = warn
  )$workers
}

worker_prediction_info <- function(
  config,
  targets = NULL,
  from_scratch = FALSE,
  targets_only = NULL,
  jobs = 1,
  known_times = numeric(0),
  default_time = 0,
  warn = TRUE
) {
  assert_config_not_plan(config)
  deprecate_targets_only(targets_only) # 2019-01-03 # nolint
  assumptions <- timing_assumptions(
    config = config,
    targets = targets,
    from_scratch = from_scratch,
    jobs = jobs,
    known_times = known_times,
    default_time = default_time,
    warn = warn
  )
  config$graph <- subset_graph(config$graph, all_targets(config))
  if (!is.null(targets)) {
    config$graph <- nbhd_graph(
      config$graph,
      vertices = targets,
      mode = "in",
      order = igraph::gorder(config$graph)
    )
  }
  queue <- priority_queue(config, jobs = 1)
  running <- data.frame(
    target = character(0),
    time = numeric(0),
    worker = integer(0),
    stringsAsFactors = FALSE
  )
  time <- 0
  workers <- replicate(jobs, character(0))
  while (!queue$empty() || nrow(running)) {
    while (length(queue$peek0()) && nrow(running) < jobs) {
      new_target <- queue$pop0()
      running <- rbind(running, data.frame(
        target = new_target,
        time = assumptions[new_target],
        worker = min(which(!(seq_len(jobs) %in% running$worker))),
        stringsAsFactors = FALSE
      ))
    }
    running <- running[order(running$time), ]
    time <- time + running$time[1]
    running$time <- running$time - running$time[1]
    workers[[running$worker[1]]] <- c(
      workers[[running$worker[1]]],
      running$target[1]
    )
    decrease_revdep_keys(
      queue = queue,
      target = running$target[1],
      config = config
    )
    running <- running[-1, ]
  }
  workers <- lapply(seq_along(workers), function(index) {
    weak_tibble(target = workers[[index]], worker = index)
  })
  workers <- do.call(rbind, workers)
  list(time = lubridate::dseconds(time), workers = workers)
}

timing_assumptions <- function(
  config,
  targets,
  from_scratch,
  jobs,
  known_times,
  default_time,
  warn
) {
  assert_pkg("lubridate")
  if (!from_scratch) {
    outdated <- outdated(config)
  }
  times <- build_times(cache = config$cache)
  vertices <- all_targets(config)
  times <- times[times$target %in% vertices, ]
  untimed <- setdiff(vertices, times$target)
  untimed <- setdiff(untimed, names(known_times))
  if (length(untimed)) {
    warning(
      "Some targets were never actually timed, ",
      "And no hypothetical time was specified in `known_times`. ",
      "Assuming a runtime of ",
      default_time, " for these targets:\n",
      multiline_message(untimed),
      call. = FALSE
    )
  }
  keep_known_times <- intersect(names(known_times), vertices)
  known_times <- known_times[keep_known_times]
  assumptions <- rep(default_time, length(vertices))
  names(assumptions) <- vertices
  assumptions[times$target] <- times$elapsed
  assumptions[names(known_times)] <- known_times
  if (!from_scratch) {
    skip <- setdiff(all_targets(config), outdated)
    assumptions[skip] <- 0
  }
  assumptions
}
