local_build <- function(target, config, downstream) {
  meta <- drake_meta_(target = target, config = config)
  if (handle_trigger(target, meta, config)) {
    return()
  }
  announce_build(target, meta, config)
  manage_memory(
    target,
    config,
    downstream = downstream,
    jobs = config$jobs_preprocess
  )
  build <- try_build(target = target, meta = meta, config = config)
  conclude_build(build = build, config = config)
  invisible()
}

announce_build <- function(target, meta, config) {
  set_progress(
    target = target,
    meta = meta,
    value = "running",
    config = config
  )
  log_msg(
    "target",
    target,
    target = target,
    config = config,
    color = "target",
    tier = 1L
  )
}

try_build <- function(target, meta, config) {
  if (identical(config$garbage_collection, TRUE)) {
    on.exit(gc())
  }
  retries <- 0L
  layout <- config$layout[[target]] %||% list()
  max_retries <- as.numeric(layout$retries %||NA% config$retries)
  while (retries <= max_retries) {
    if (retries > 0L) {
      log_msg(
        "retry",
        target,
        retries,
        "of",
        max_retries,
        target = target,
        config = config,
        color = "retry",
        tier = 1L
      )
    }
    build <- with_seed_timeout(
      target = target,
      meta = meta,
      config = config
    )
    if (!inherits(build$meta$error, "error")) {
      return(build)
    }
    retries <- retries + 1L
  }
  build
}

with_seed_timeout <- function(target, meta, config) {
  timeouts <- resolve_timeouts(target = target, config = config)
  with_timeout(
    with_seed(
      meta$seed,
      with_handling(
        target = target,
        meta = meta,
        config = config
      )
    ),
    cpu = timeouts[["cpu"]],
    elapsed = timeouts[["elapsed"]]
  )
}

resolve_timeouts <- function(target, config) {
  layout <- config$layout[[target]] %||% list()
  vapply(
    X = c("cpu", "elapsed"),
    FUN = function(key) {
      layout[[key]] %||NA% config[[key]]
    },
    FUN.VALUE = numeric(1)
  )
}

# Taken from `R.utils::withTimeout()` and simplified.
# https://github.com/HenrikBengtsson/R.utils/blob/13e9d000ac9900bfbbdf24096d635da723da76c8/R/withTimeout.R # nolint
# Copyright Henrik Bengtsson, LGPL >= 2.1.
with_timeout <- function(expr, cpu, elapsed) {
  if (cpu < Inf || elapsed < Inf) {
    setTimeLimit(cpu = cpu, elapsed = elapsed, transient = TRUE)
    on.exit(setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE))
  }
  expr <- substitute(expr)
  envir <- parent.frame()
  eval(expr, envir = envir)
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
with_seed <- function(seed, code) {
  force(seed)
  with_preserve_seed({
    set.seed(seed)
    code
  })
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
with_preserve_seed <- function(code) {
  old_seed <- get_valid_seed()
  on.exit(assign(".Random.seed", old_seed, globalenv()), add = TRUE)
  code
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
get_valid_seed <- function() {
  seed <- get_seed()
  if (is.null(seed)) {
    # Trigger initialisation of RNG
    sample.int(1L) # nocov
    seed <- get_seed() # nocov
  }
  seed
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
get_seed <- function() {
  no_seed_yet <- !exists(
    ".Random.seed",
    globalenv(),
    mode = "integer",
    inherits = FALSE
  )
  if (no_seed_yet) {
    return(NULL) # nocov
  }
  get(".Random.seed", globalenv(), mode = "integer", inherits = FALSE)
}

# The beginnings of with_handling() were borrowed from the rmonad package.
# Lots of modifications since.
# Copyright Zebulun Arendsee, GPL-3:
# https://github.com/arendsee/rmonad/blob/14bf2ef95c81be5307e295e8458ef8fb2b074dee/R/to-monad.R#L68 # nolint
with_handling <- function(target, meta, config) {
  warnings <- messages <- NULL
  start <- proc.time()
  withCallingHandlers(
    value <- with_call_stack(target = target, config = config),
    warning = function(w) {
      drake_log(
        paste("Warning:", w$message),
        target = target,
        config = config
      )
      warnings <<- c(warnings, w$message)
      invokeRestart("muffleWarning")
    },
    message = function(m) {
      msg <- gsub(pattern = "\n$", replacement = "", x = m$message)
      drake_log(
        msg,
        target = target,
        config = config
      )
      messages <<- c(messages, msg)
      invokeRestart("muffleMessage")
    }
  )
  meta$time_command <- proc.time() - start
  meta$warnings <- prepend_fork_advice(warnings)
  meta$messages <- messages
  if (inherits(value, "error")) {
    value$message <- prepend_fork_advice(value$message)
    meta$error <- value
    value <- NULL
  }
  list(
    target = target,
    meta = meta,
    value = value
  )
}

prepend_fork_advice <- function(msg) {
  if (!length(msg)) {
    return(msg)
  }
  # Loop so we can use fixed = TRUE, which is fast. # nolint
  fork_error <- sum(vapply(
    c("parallel", "core"),
    function(pattern) any(grepl(pattern, msg, fixed = TRUE)),
    FUN.VALUE = logical(1)
  ))
  if (!fork_error) {
    return(msg)
  }
  out <- paste(
    "\n Having problems with parallel::mclapply(),",
    "future::future(), or furrr::future_map() in drake?",
    "Try one of the workarounds at",
    "https://ropenscilabs.github.io/drake-manual/hpc.html#parallel-computing-within-targets", # nolint
    "or https://github.com/ropensci/drake/issues/675. \n\n"
  )
  c(out, msg)
}

# Taken directly from the `evaluate::try_capture_stack()`.
# https://github.com/r-lib/evaluate/blob/b43d54f1ea2fe4296f53316754a28246903cd703/R/traceback.r#L20-L47 # nolint
# Copyright Hadley Wickham and Yihui Xie, 2008 - 2018. MIT license.
with_call_stack <- function(target, config) {
  frame <- sys.nframe()
  capture_calls <- function(e) {
    e <- mention_pure_functions(e)
    e$calls <- head(sys.calls()[-seq_len(frame + 7)], -2)
    signalCondition(e)
  }
  expr <- config$layout[[target]]$command_build
  # Need to make sure the environment is locked for running commands.
  # Why not just do this once at the beginning of `make()`?
  # Because do_prework() and future::value()
  # may need to modify the global state.
  # Unfortunately, we have to repeatedly lock and unlock the envir.
  # Unfortunately, the safe way to do this adds overhead and
  # makes future::multicore parallelism serial.
  if (config$lock_envir) {
    i <- 1
    # Lock the environment only while running the command.
    while (environmentIsLocked(config$envir)) {
      Sys.sleep(config$sleep(max(0L, i))) # nocov
      i <- i + 1 # nocov
    }
    lock_environment(config$envir)
    on.exit(unlock_environment(config$envir))
  }
  config$eval[[drake_target_marker]] <- target
  tidy_expr <- eval(expr = expr, envir = config$eval) # tidy eval prep
  tryCatch(
    withCallingHandlers(
      eval(expr = tidy_expr, envir <- config$eval), # pure eval
      error = capture_calls
    ),
    error = identity
  )
}

lock_environment <- function(envir) {
  lockEnvironment(envir, bindings = FALSE)
  lapply(X = unhidden_names(envir), FUN = lockBinding, env = envir)
  invisible()
}

unlock_environment <- function(envir) {
  if (is.null(envir)) {
    stop("use of NULL environment is defunct")
  }
  if (!inherits(envir, "environment")) {
    stop("not an environment")
  }
  .Call(Cunlock_environment, envir)
  lapply(
    X = unhidden_names(envir),
    FUN = unlockBinding,
    env = envir
  )
  stopifnot(!environmentIsLocked(envir))
}

unhidden_names <- function(envir) {
  out <- names(envir)
  out <- out[substr(out, 0, 1) != "."]
  out
}

mention_pure_functions <- function(e) {
  msg1 <- "locked binding"
  msg2 <- "locked environment"
  locked_envir <- grepl(msg1, e$message) || grepl(msg2, e$message)
  if (locked_envir) {
    e$message <- paste0(e$message, ". ", locked_envir_msg)
  }
  e
}

locked_envir_msg <- paste(
  "\nPlease read the \"Self-invalidation\"",
  "section of the make() help file."
)

conclude_build <- function(build, config) {
  target <- build$target
  value <- build$value
  meta <- build$meta
  assert_output_files(target = target, meta = meta, config = config)
  handle_build_exceptions(target = target, meta = meta, config = config)
  store_outputs(target = target, value = value, meta = meta, config = config)
  assign_to_envir(target = target, value = value, config = config)
  invisible(value)
}

assign_to_envir <- function(target, value, config) {
  memory_strategy <- config$layout[[target]]$memory_strategy %||NA%
    config$memory_strategy
  if (memory_strategy %in% c("autoclean", "unload", "none")) {
    return()
  }
  if (
    identical(config$lazy_load, "eager") &&
    !is_encoded_path(target) &&
    !is_imported(target, config)
  ) {
    assign(x = target, value = value, envir = config$eval)
  }
  invisible()
}

assert_output_files <- function(target, meta, config) {
  deps <- config$layout[[target]]$deps_build
  if (!length(deps$file_out)) {
    return()
  }
  files <- unique(as.character(deps$file_out))
  files <- decode_path(files, config)
  missing_files <- files[!file.exists(files)]
  if (length(missing_files)) {
    msg <- paste0(
      "Missing files for target ",
      target, ":\n",
      multiline_message(missing_files)
    )
    drake_log(paste("Warning:", msg), config = config)
    warning(msg, call. = FALSE)
  }
}

handle_build_exceptions <- function(target, meta, config) {
  if (length(meta$warnings) && config$verbose) {
    warn_opt <- max(1, getOption("warn"))
    with_options(
      new = list(warn = warn_opt),
      warning(
        "target ", target, " warnings:\n",
        multiline_message(meta$warnings),
        call. = FALSE
      )
    )
  }
  if (length(meta$messages) && config$verbose) {
    message(
      "Target ", target, " messages:\n",
      multiline_message(meta$messages)
    )
  }
  if (inherits(meta$error, "error")) {
    log_msg(
      "fail",
      target,
      target = target,
      config = config,
      color = "fail",
      tier = 1L
    )
    store_failure(target = target, meta = meta, config = config)
    if (!config$keep_going) {
      msg <- paste0(
        "Target `", target, "` failed. Call `diagnose(", target,
        ")` for details. Error message:\n  ",
        meta$error$message
      )
      drake_log(paste("Error:", msg), config = config)
      unlock_environment(config$envir)
      stop(msg, call. = FALSE)
    }
  }
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
with_options <- function(new, code) {
  old <- set_options(new_options = new)
  on.exit(set_options(new_options = old))
  force(code)
}

# From withr https://github.com/r-lib/withr, copyright RStudio, GPL (>=2)
set_options <- function(new_options) {
  do.call(options, as.list(new_options))
}

store_failure <- function(target, meta, config) {
  set_progress(
    target = target,
    meta = meta,
    value = "failed",
    config = config
  )
  fields <- intersect(c("messages", "warnings", "error"), names(meta))
  meta <- meta[fields]
  config$cache$set(
    key = target,
    value = meta,
    namespace = "meta",
    use_cache = FALSE
  )
}

set_progress <- function(target, meta, value, config) {
  skip_progress <- !identical(config$running_make, TRUE) ||
    !config$log_progress ||
    (meta$imported %||% FALSE)
  if (skip_progress) {
    return()
  }
  config$cache$driver$set_hash(
    key = target,
    namespace = "progress",
    hash = config$cache$ht_progress[[value]]
  )
}
