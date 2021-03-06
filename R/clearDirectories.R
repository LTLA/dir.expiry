#' Clear expired directories
#'
#' Remove versioned directories that have passed on expiration limit.
#'
#' @param dir String containing the path to a package cache containing any number of versioned directories.
#' @param reference A \link{package_version} specifying a reference version to be protected from deletion.
#' @param limit Integer scalar specifying the maximum number of days to have passed before a versioned directory expires.
#' @param force Logical scalar indicating whether to forcibly re-examine \code{dir} for expired versioned directories.
#' 
#' @return Expired directories are deleted and \code{NULL} is invisibly returned.
#'
#' @author Aaron Lun
#'
#' @details
#' This function checks the last access date in the \code{*_dir.expiry} files in \code{dir}.
#' If the last access date is too old, the corresponding subdirectory in \code{path} is treated as expired and is deleted.
#' The age threshold depends on \code{limit}, which defaults to the value of the environment variable \code{BIOC_DIR_EXPIRY_LIMIT}.
#' If this is not specified, it is set to 30 days.
#'
#' If \code{reference} is specified, any directory of that name is protected from deletion.
#' In addition, directories with version numbers greater than (or equal to) \code{reference} are not deleted,
#' even if their last access date was older than the specified \code{limit}.
#' This aims to favor the retention of newer versions, which is generally a sensible outcome when the aim is to stay up-to-date.
#' 
#' This function will acquire exclusive locks on the package cache directory and on each versioned directory before attempting to delete the latter.
#' Applications can achieve thread safety by calling \code{\link{lockDirectory}} prior to any operations on the versioned directory.
#' This ensures that \code{clearDirectories} will not delete a directory in use by another process, especially if the latter might update the last access time.
#'
#' By default, this function will remember the values of \code{dir} that were passed in previous calls,
#' and will avoid re-examining those same \code{dir}s for expired directories on the same day.
#' This avoids unnecessary file system queries and locks when this function is repeatedly called.
#' Advanced users can force a re-examination by setting \code{force=TRUE}.
#' 
#' @examples
#' # Creating the package cache.
#' cache.dir <- tempfile(pattern="expired_demo")
#'
#' # Creating an older versioned directory.
#' version <- package_version("1.11.0")
#' version.dir <- file.path(cache.dir, version)
#'
#' lck <- lockDirectory(version.dir)
#' dir.create(version.dir)
#' touchDirectory(version.dir, date=Sys.Date() - 100)
#' unlockDirectory(lck, clear=FALSE) # manually clear below.
#'
#' list.files(cache.dir)
#'
#' # Clearing them out.
#' clearDirectories(cache.dir)
#' list.files(cache.dir)
#' 
#' @seealso
#' \code{\link{touchDirectory}}, which calls this function automatically when \code{clear=TRUE}.
#' @export
clearDirectories <- function(dir, reference=NULL, limit=NULL, force=FALSE) {
    if (.was_checked_today(dir, cleared.env) && !force) {
        return(invisible(NULL))
    }

    if (is.null(limit)) {
        limit <- Sys.getenv("BIOC_DIR_EXPIRY_LIMIT", "30")
        limit <- as.integer(limit)
    } 

    # Unlike lockDirectory, this is exclusive as we will be deleting the lock
    # files; no point allowing other processes to touch them in the meantime.
    # We put the locking here so as to ensure that the files don't disappear
    # between the list.files() and the actual removal.
    plock <- .plock_path(dir)
    p <- lock(plock) 
    on.exit(unlock(p))

    pattern <- paste0(expiry.suffix, "$")
    all.files <- list.files(dir, pattern=pattern)
    if (!is.null(reference)) {
        all.files <- setdiff(all.files, paste0(as.character(reference), expiry.suffix))
        if (is.character(reference)) {
            reference <- package_version(reference)
        }
    }

    current <- as.integer(Sys.Date())
    for (x in all.files) {
        version <- sub(pattern, "", x)
        .delete_versioned_directory(dir, version=version, expfile=x, date=current, reference=reference, limit=limit)
    }

    invisible(NULL)
}

cleared.env <- new.env()
cleared.env$status <- list()

#' @importFrom filelock lock unlock
.delete_versioned_directory <- function(dir, version, expfile, date, reference, limit) {
    # Protect against simultaneous accesses to the targeted directory,
    # assuming users called lockDirectory() before touchDirectory().
    path <- file.path(dir, version)
    vlock <- .vlock_path(path)
    V <- lock(vlock)

    deleted <- FALSE
    on.exit({ 
        unlock(V)
        if (deleted) {
            unlink(vlock)
        }
    }, add=TRUE, after=FALSE)

    acc.path <- file.path(dir, expfile)
    last.used <- as.integer(read.dcf(acc.path)[,"AccessDate"])
    diff <- date - last.used

    if (diff > limit && (is.null(reference) || reference > package_version(version))) {
        unlink(acc.path, force=TRUE)
        unlink(paste0(acc.path, lock.suffix), force=TRUE)
        unlink(path, recursive=TRUE, force=TRUE)
        deleted <- TRUE
    }
}
