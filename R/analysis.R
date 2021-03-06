#' Multiple clusters from a parameter set
#'
#' Runs a given clustering method (a passed function) over a range of parameter 
#' values (a list, each entry a named list of parameters for the function).
#' Collects the data into a single data table with multiple cluster set ID's 
#' indicating the parameter set used to define clusters a unique cluster range ID.
#' 
#' @param cluster.method: A given clustering function such as step.cluster() which 
#' produces a set of clusters.
#' @param param.list: A list, each entry a named list of parameter sets which can 
#' act as inputs to the cluster.method. These include values such as trees and graphs, 
#' as well as  criteria for clustering such as boot.thresh or dist.thresh.
#' @param rangeID: A unique identifier for the set of rows generated by this run
#' if this output is bound to other cluster ranges in a larger analysis.
#' @param mc.cores: A parallel option to increase run speed.
#' @return A data.table of clusters. Multiple cluster sets are collected into a range.
#' @export
#' @example examples/multi.cluster_ex.R
multi.cluster <- function(cluster.method, param.list, mc.cores = 1, rangeID = 0) {

  # Cluster method loop
  cluster.range <- parallel::mclapply(1:length(param.list), function(i) {
    x <- param.list[[i]]
    x$setID <- i
    suppressWarnings(do.call(cluster.method, x))
  }, mc.cores = mc.cores)

  cluster.range <- dplyr::bind_rows(cluster.range)
  suppressWarnings(cluster.range[, "RangeID" := rangeID])

  return(cluster.range)
}

#' Predictive analysis on clusters
#'
#' Fits predictive model of some outcome (by default, cluster growth) to some 
#' cluster-level variable (by default, cluster size). This fit is done for each 
#' cluster set. Multiple models can be inputted as a named list of functions taking 
#' in cluster data (see example)
#'
#' @param cluster.data: Inputted set(s) of clusters. Possibly multiple ranges
#' @param mc.cores: A parallel option to increase run speed
#' @param predictor.transformations: A named list of transformation functions for 
#' each predictor variable (ex. list("Data"==sum). Because clustered meta data takes 
#' the form of a list these functions are often necessary to obtain a single, 
#' cluster-level variable
#' @param predictive.models: A named list of functions, each of which applies a 
#' model to inputted cluster data (x). By default a "NullModel" example. Where
#' Growth is predicted only by cluster size
#' @return A data.table of analysis results. Model fits are stored as entries in 
#' the rows of a data.table. The column specifying setID is retained, as is the 
#' range ID and the parameters used to create the cluster.
#' @export
#' @example examples/fit.analysis_ex.R
fit.analysis <- function(cluster.data, mc.cores = 1, predictor.transformations = list(),
                         predictive.models = list(
                           "NullModel" = function(x){
                             glm(Size~Growth, data=x, family="poisson")
                            })) {
  
  # Check inputs
  predictors <- names(predictor.transformations)
  mod.names <- names(predictive.models)
  setIDs <- unique(cluster.data[, SetID])
  if (!all((predictors) %in% colnames(cluster.data))) {
    stop("Predictors referenced in transform step are not in the range of cluster data")
  }
  if (!("RangeID" %in% colnames(cluster.data))) {
    warning("No range ID, by default this will be set to 0 for all sets")
    cluster.data[, "RangeID" := 0]
  }

  # Transform cluster data for modelling based on inputs
  model.data <- cluster.data[, c("Header", "Size", "Growth", "SetID", "RangeID")]

  if(!is.null(predictors)) {
    model.data[, (predictors) := lapply(predictors, function(x) {
      sapply(cluster.data[, get(x)], function(z) {
        (predictor.transformations[[x]])(z)
      })
    })]
  }

  # Obtain fit data for each cluster set
  cluster.analysis <- dplyr::bind_rows(
    parallel::mclapply(setIDs, function(id) {
      DT <- model.data[SetID == id, ]

      res <- data.table::data.table("SetID" = DT[1, SetID], "RangeID" = DT[1, RangeID])
      res[, (mod.names) := lapply(predictive.models, function(pmod){
        suppressWarnings(list(pmod(DT)))
      })]
      return(res)
    }, mc.cores = mc.cores)
  )

  return(cluster.analysis)
}

#'Get AIC values from an analysis
#'
#'Takes a cluster.analysis and extracts AIC values from columns containing model 
#'fits. Fit columns are automatically identified
#'
#'@param cluster.analysis: A data.table from some predictive growth model analysis 
#'generated by fit.analysis()
#'@return The AIC data for all columns containing fit objects. The column specifying 
#'setID is retained
#'@export
#'@example examples/get.AIC_ex.R
get.AIC <- function(cluster.analysis){

  #Identify models
  which.models <- sapply(cluster.analysis[1,], 
                         function(x){any(attr(x[[1]], "class")%in%c("lm", "glm"))})
  which.models <- which(which.models)
  if(length(which.models)==0) {
    stop("No fits in the data set provided")
  }
  model.fits <- cluster.analysis[,.SD, .SDcols = which.models]

  #Return specifically aic as a new data.table
  newnms <- sapply(names(which.models), function(nm){paste0(nm,"AIC")})
  aic.analysis <- data.table::data.table()
  aic.analysis[,(newnms) := lapply(names(which.models), function(nm){
    sapply(model.fits[,get(nm)], function(x){x$aic})
  })]

  return(aic.analysis)
}
