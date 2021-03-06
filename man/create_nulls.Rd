% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/create_null.R
\name{create_nulls}
\alias{create_nulls}
\title{Create RDS for all empty pixels}
\usage{
create_nulls(files, path, channels)
}
\arguments{
\item{files}{The paths of the _Array.R files}

\item{path}{The path of where to save the created RDS files}

\item{channels}{Character vector with name(s) of channels. Channel names should be in the names of the .tif files}
}
\value{
Creates arrays as RDS files in the specified path, and outputs the paths for these files
}
\description{
Create arrays which represents all the empty pixels in an image
}
\keyword{array}
\keyword{image}
