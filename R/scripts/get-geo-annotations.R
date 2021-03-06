#!/usr/bin/env Rscript

##########################################################
####  Access metadata from GEO and export as a table  ####
##########################################################

## Sample usage:
## $ Rscript get-geo-annotations.R --gse "GSE89777" > manifest.tsv

## Load packages
usePackage <- function(p) 
{
  if (!is.element(p, installed.packages()[,1]))
    install.packages(p, repos = "http://cran.us.r-project.org", dep = TRUE)
  require(p, character.only = TRUE)
}
usePackage("pacman")

suppressPackageStartupMessages(p_load("GEOquery"))
suppressPackageStartupMessages(p_load("SRAdb"))
suppressPackageStartupMessages(p_load("plyr"))
suppressPackageStartupMessages(p_load("optparse"))
suppressPackageStartupMessages(p_load("xml2"))
suppressPackageStartupMessages(p_load("rentrez"))

option_list <- list(
                    make_option(c("--gse"), action="store",
                                default=NULL,
                                help="GEO Series accession number (e.g., \"GSE89777\")"))

descr <- "\
Extract GEO annotations from the GEO data set with identifier specified by 'GSE'.  If the data set has SRA entries, the ftp directory is expected to be specified in GEO annotation fields that include the pattern 'supplementary_file'.  This field will be parsed to extract the SRA identifier, which will be used to determine the URL of the FTP file.  Whether an SRA data set or not, the URL will be included in the 'url' column of the output.
"

parser <- OptionParser(usage = "%prog [options]", option_list=option_list, description=descr)

arguments <- parse_args(parser, positional_arguments = TRUE)
opt <- arguments$options

## Collect input parameters
gse.identifier <- opt$gse

if ( length(arguments$args) != 0 ) {
  print_help(parser)
  q(status=1)
}

if ( is.null(gse.identifier) ) {
  print_help(parser)
  q(status=1)
}

options('download.file.method.GEOquery' = 'libcurl')

## Get the GSE object
message(paste0("Retrieving the GSE object for identifier: ", gse.identifier, "\n"))
gse.geo <- getGEO(gse.identifier, getGPL=FALSE)

## Iterate over each of the GSMs associated with this GSE
metadata.tbl <- ldply(sampleNames(phenoData(gse.geo[[1]])), 
                      .fun = function(gsm.identifier) {

                        message(paste0("Retrieving metadata for GSM identifier: ", gsm.identifier, "\n"))
                          
                        ## Get the GSM object
                        gsm.geo <- getGEO(gsm.identifier)
        
                        ## Extract its metadata
                        md <- Meta(gsm.geo)
                        
                        ## Metadata is a list of lists.
                        ## Go through each entry and concatenate the individual lists using a ';' delimiter
                        as.data.frame(lapply(md, function(entry) paste(entry, collapse=";")), stringsAsFactors = FALSE)
                      })

## If these are SRA entries, the entity listed in supplementary_file will be a directory
## not a URL.  Do a little more work to find that URL.
supp.file.columns <- colnames(metadata.tbl)[grepl(colnames(metadata.tbl), pattern="supplementary_file")]
if(length(supp.file.columns) == 0) {
    stop(paste0("Could not find a column name with pattern \"supplementary_file\" in columns:\n", paste(colnames(metadata.tbl), collapse=", "), "\n"))
}

if(length(supp.file.columns) > 1) {
    warning(paste0("Got multiple columns with pattern \"supplementary_file\"\nJust using the first of the following:\n", paste(supp.file.columns, collpase=", "), "\n"))
}

metadata.tbl$url <- as.character(metadata.tbl[, supp.file.columns[1]])

## Function to find FTP link by searching Entrez and parsing the XML results
get_link_from_entrez <- function(sra) {
  search_results <- entrez_search(db = "sra", term = paste0(sra, "[Accession]"))
  if (length(search_results$ids) > 1) {
    stop("Too many ids found", call. = FALSE)
  }
  ## Fetch entity via entrez
  entity <- entrez_fetch(db = "sra", id = search_results$id, rettype = "xml")

  ## Parse XML and find the id that corresponds to the SRA file (this is
  ## different than the SRA id)
  entity_xml <- read_xml(entity)
  id <- xml_text(xml_find_first(entity_xml, "//RUN_SET/RUN/IDENTIFIERS"))

  ## Build path to FTP
  base_path <- "ftp://ftp-trace.ncbi.nih.gov/sra/sra-instant/reads/ByRun/sra"
  first3 <- substr(id, 1, 3)
  first6 <- substr(id, 1, 6)
  ftp <- paste(base_path, first3, first6, id, paste0(id, ".sra"), sep = "/")
  ftp
}

## Function to find FTP link. First it tries Entrez using the
## `get_link_from_entrez()` function above; if that doesn't work, it tries
## downloading the SRA database
get_link <- function(sra) {
  url <- try(get_link_from_entrez(sra))
  if (inherits(url, "try-error")) {
    message("Could not find link through Entrez; trying SRA database next")
    sra.db.dest.file <- "SRAmetadb.sqlite"
    if(!file.exists(sra.db.dest.file)) {
      ## Download SRA database file. Note this is large (~35 GB as of 2018-12-19)
      ## so will take some time
      sra.db.dest.file <- getSRAdbFile(destfile = paste0(sra.db.dest.file, ".gz"))
    }
    con <- dbConnect(RSQLite::SQLite(), sra.db.dest.file)
    url <- try(listSRAfile(sra, con)$ftp, silent = TRUE)
    d <- dbDisconnect(con)
  }
  if (inherits(url, "try-error")) {
    warning("Could not find FTP link to SRA file", call. = FALSE)
    url <- NA
  }
  return(url)
}

## Look up FTP links for SRA files in metadata.tbl and add to url column
if (any(metadata.tbl$type == "SRA")) {
  for (i in seq_len(nrow(metadata.tbl))) {
    if (metadata.tbl$type[i] == "SRA") {
      relation <- metadata.tbl$relation[i]
      ## Extract SRA id
      sra.identifier <- gsub("^(.+?)sra\\?term=(.+)$", "\\2", relation)
      ## Get FTP link
      metadata.tbl$url[i] <- get_link(sra.identifier)
    }
  }
}

write.table(metadata.tbl, sep="\t", quote=FALSE, row.names=FALSE, col.names=TRUE)

message("Successfully completed\n")
q(status = 0)
