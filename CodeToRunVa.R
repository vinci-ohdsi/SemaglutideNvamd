
# ENVIRONMENT SETTINGS NEEDED FOR RUNNING STUDY IN ENVIRONMENT ------------
Sys.setenv("_JAVA_OPTIONS"="-Xmx4g") # Sets the Java maximum heap space to 4GB
Sys.setenv("VROOM_THREADS"=1) # Sets the number of threads to 1 to avoid deadlocks on file system

Sys.setenv(JAVA_HOME="extras/jdk1.8") # "d:/jdk1.8"
Sys.setenv(DATABASECONNECTOR_JAR_FOLDER="extras") # "d:/JDBC/installed_12.4"

connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server",
  server = "SERVER NAME HERE"
)

# Only needs to be executed once
# VaTools::createStandardCdmSchema(
#   connectionDetails = connectionDetails,
#   database = "ORD_Researcher_xyz",
#   startingSchema = "src",
#   destinationSchema = "OMOPV5")

databaseName <- "VA-OMOP"
workDatabaseSchema <- "ORD_Researcher_xyz.scratch_msuchard" # VINCI_OMOP
cdmDatabaseSchema <- "ORD_Researcher_xyz.OMOPV5" # CDW_OMOP
outputLocation <- "D:/OHDSI/MAS/output"
minCellCount <- 10
cohortTableName <- "sema_nvamd"

assignInNamespace(
  "checkTimeStabilityAssumption",
  function(studyPopulation, sccsModel = NULL, maxRatio = 1.10, alpha = 0.05) {
    errorMessages <- checkmate::makeAssertCollection()
    checkmate::assertList(studyPopulation, min.len = 1, add = errorMessages)
    checkmate::assertClass(sccsModel, "SccsModel", null.ok = TRUE, add = errorMessages)
    checkmate::assertNumeric(maxRatio, lower = 1, len = 1, add = errorMessages)
    checkmate::assertNumber(alpha, lower = 0, upper = 1, add = errorMessages)
    checkmate::reportAssertions(collection = errorMessages)
    
    data <- SelfControlledCaseSeries:::computeOutcomeRatePerMonth(studyPopulation, sccsModel)
    if (nrow(data) < 2) {
      result <- dplyr::tibble(ratio = NA,
                       p = 1,
                       pass = TRUE)
      return(result)
    }
    o <- data$observedCount
    e <- data$adjustedExpectedCount
    e[e == 0] <- .Machine$double.eps
    
    logLikelihood <- function(x) {
      return(-sum(pmax(-999, log(dpois(o, e*x) + dpois(o, e/x))))) # EXPEDIENT HACK
    }
    x <- seq(1, 10, by = 0.1)
    ll <- sapply(x, logLikelihood)
    maxX <- x[max(which(!is.na(ll) & !is.infinite(ll)))]
    minX <- x[min(which(!is.na(ll) & !is.infinite(ll)))]
    xHat <- optim(1.5, logLikelihood, lower = minX, upper = maxX, method = "L-BFGS-B")$par
    x0 <- if (xHat > maxRatio) maxRatio else xHat
    x1 <- if (xHat < maxRatio) maxRatio else xHat
    ll0 <- -logLikelihood(x0)
    ll1 <- -logLikelihood(x1)
    llr <- 2 * (ll1 - ll0)
    if (is.nan(llr)) {
      if (xHat > maxRatio) {
        p <- 0
      } else {
        p <- 1
      }
    } else {
      p <- pchisq(llr, 1, lower.tail = FALSE)
    }
    result <- dplyr::tibble(ratio = xHat,
                     p = p,
                     pass = p > alpha)
    return(result)
  },
  ns = "SelfControlledCaseSeries")



##=========== END OF INPUTS ==========
analysisSpecifications <- ParallelLogger::loadSettingsFromJson(
  fileName = "inst/fullStudyAnalysisSpecification.json"
)

executionSettings <- Strategus::createCdmExecutionSettings(
  workDatabaseSchema = workDatabaseSchema,
  cdmDatabaseSchema = cdmDatabaseSchema,
  cohortTableNames = CohortGenerator::getCohortTableNames(cohortTable = cohortTableName),
  workFolder = file.path(outputLocation, databaseName, "strategusWork"),
  resultsFolder = file.path(outputLocation, databaseName, "strategusOutput"),
  minCellCount = minCellCount
)

if (!dir.exists(file.path(outputLocation, databaseName))) {
  dir.create(file.path(outputLocation, databaseName), recursive = T)
}
ParallelLogger::saveSettingsToJson(
  object = executionSettings,
  fileName = file.path(outputLocation, databaseName, "executionSettings.json")
)

## VA SPECIFIC CODE START ---------
library(Strategus)

CohortGeneratorModule$set(
  "public", "execute", 
  function(connectionDetails, analysisSpecifications, executionSettings) {
    super$.validateCdmExecutionSettings(executionSettings)
    super$execute(connectionDetails, analysisSpecifications, executionSettings)
    
    jobContext <- private$jobContext
    cohortDefinitionSet <- super$.createCohortDefinitionSetFromJobContext()
    
    message("Running VA-specific refactoring")
    if (TRUE) {
      for (i in 1:nrow(cohortDefinitionSet)) {
        newSql <- VaTools::translateToCustomVaSqlUsingJava(cohortDefinitionSet$sql[i])         
        cohortDefinitionSet$sql[i] <- newSql
      }
    }    
    
    negativeControlOutcomeSettings <- private$.createNegativeControlOutcomeSettingsFromJobContext()
    resultsFolder <- jobContext$moduleExecutionSettings$resultsSubFolder
    if (!dir.exists(resultsFolder)) {
      dir.create(resultsFolder, recursive = TRUE)
    }
    
    CohortGenerator::runCohortGeneration(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = jobContext$moduleExecutionSettings$cdmDatabaseSchema,
      cohortDatabaseSchema = jobContext$moduleExecutionSettings$workDatabaseSchema,
      cohortTableNames = jobContext$moduleExecutionSettings$cohortTableNames,
      cohortDefinitionSet = cohortDefinitionSet,
      negativeControlOutcomeCohortSet = negativeControlOutcomeSettings$cohortSet,
      occurrenceType = negativeControlOutcomeSettings$occurrenceType,
      detectOnDescendants = negativeControlOutcomeSettings$detectOnDescendants,
      outputFolder = resultsFolder,
      databaseId = jobContext$moduleExecutionSettings$cdmDatabaseMetaData$databaseId,
      minCellCount = jobContext$moduleExecutionSettings$minCellCount,
      incremental = jobContext$moduleExecutionSettings$incremental,
      incrementalFolder = jobContext$moduleExecutionSettings$workSubFolder
    )
    
    private$.message(paste("Results available at:", resultsFolder))
  },
  overwrite = TRUE
)

# # Stand-alone execution the CG Module             
# cgModule <- CohortGeneratorModule$new()
# cgModule$execute(
#   connectionDetails = connectionDetails,
#   analysisSpecifications = analysisSpecifications,
#   executionSettings = executionSettings
# )
# 
# # Remove CG module from the analysis specification
# analysisSpecifications$moduleSpecifications <- analysisSpecifications$moduleSpecifications[2:5]

# Note that given the redefinition of `CohortGeneratorModule` there is no need to
# separate out its execution as is done above.

## VA SPECIFIC CODE END ---------

Strategus::execute(
  analysisSpecifications = analysisSpecifications,
  executionSettings = executionSettings,
  connectionDetails = connectionDetails
)
