% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/deprecated.R
\name{drake_session}
\alias{drake_session}
\title{Deprecated. Return the \code{\link[=sessionInfo]{sessionInfo()}}
of the last call to \code{\link[=make]{make()}}.}
\usage{
drake_session(path = getwd(), search = TRUE,
  cache = drake::get_cache(path = path, search = search, verbose =
  verbose), verbose = 1L)
}
\arguments{
\item{path}{Path to a \code{drake} cache
(usually a hidden \code{.drake/} folder) or \code{NULL}.}

\item{search}{Deprecated.}

\item{cache}{drake cache. See \code{\link[=new_cache]{new_cache()}}.
If supplied, \code{path} is ignored.}

\item{verbose}{Integer, control printing to the console/terminal.
\itemize{
\item \code{0}: print nothing.
\item \code{1}: print targets, retries, and failures.
\item \code{2}: also show a spinner when preprocessing tasks are underway.
}}
}
\value{
\code{\link[=sessionInfo]{sessionInfo()}} of the last call to \code{\link[=make]{make()}}
}
\description{
Deprecated. Use \code{\link[=drake_get_session_info]{drake_get_session_info()}} instead.
}
\details{
Deprecated on 2018-12-06.
}
\keyword{internal}
