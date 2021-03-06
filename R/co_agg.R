#' 3D co-aggregation
#'
#' Function to calculate the pairwise 3D co-aggregation between two channels
#' @param imgs The paths of array files; i.e. output from \code{loadIMG} or \code{findIMG} functions.
#' @param channels Character vector with names of the two channels to calculate co-aggregation for. Should be in the names of the array files
#' @param size The maximum distance (microns) to examine. Has to be a multiple of both pwidth and zstep. Beware, increasing size will increase runtime exponetially!
#' @param npixel Number of random pixels to examine. Increasing this will increase precision (and runtime in a linear fashion)
#' @param R Number of times to run the co-aggregation analysis
#' @param dstep The interval between examined distances (microns). Increasing this decreases resolution but speeds up function linearly. Defaults to 1
#' @param pwidth Width of pixels in microns
#' @param zstep z-step in microns
#' @param cores The number of cores to use. Defaults to 1
#' @param kern.smooth Optional. Numeric vector indicating range of median smoothing in the x,y,z directions. Has to be odd intergers. c(1,1,1) means no smoothing.
#' @param layers Optional. Should the function only look in a subset of layers. A list with lists of layers to use for each image. Can also be the output from \code{extract_layers} 
#' @param naming Optional. Add metadata to the output dataframe by looking through names of array files. Should be a list of character vectors, each list element will be added as a variable. Example: naming=list(Time=c("T0","T1","T2")). The function inserts a variable called Time, and then looks through the names of the array files and inserts characters mathcing either T0, T1 or T2
#' @keywords array image co-aggregation
#' @return A dataframe with the co-aggregation values for each distance
#' @import doSNOW
#' @import parallel
#' @import foreach
#' @import fastmatch
#' @export

co_agg <- function(imgs,channels,size,npixel,R=10,dstep=1,pwidth,zstep,cores=1,kern.smooth=NULL,layers=NULL,naming=NULL){
  
  if(size%%zstep != 0) if(all.equal(size%%zstep,zstep)!=TRUE) stop("size not a multiple of zstep")
  if(size%%pwidth != 0) if(all.equal(size%%pwidth,pwidth)!=TRUE) stop("size not a multiple of pwidth")
  
  stopifnot(length(channels)==2)

  CC.all <- list()
  for(r in 1:R){
    message(paste("Starting run "),r)
    CC <- co_agg.default(imgs,channels,size,npixel,dstep,pwidth,zstep,cores,kern.smooth,layers,naming)
    CC$R <- r
    CC.all[[r]] <- CC
  }
  CCall <- do.call("rbind", CC.all)

  return(CCall)
}

#' @rdname co_agg
#' @export

co_agg.default <- function(imgs,channels,size,npixel,dstep=1,pwidth,zstep,cores=1,kern.smooth=NULL,layers=NULL,naming=NULL) {
  
  # Null box (pixels)
  null_box <- expand.grid(x = seq((-size/pwidth), (size/pwidth), by = 1), 
                          y = seq((-size/pwidth), (size/pwidth), by = 1), 
                          z = seq((-size/zstep), (size/zstep), by = 1))
  
  # Distances from focal pixel to each pixel in box (distances in microns, position in pixel space)
  d <- apply(null_box,1,function(nbox) sqrt((0 - (nbox[1]*pwidth))^2 +
                                              (0 - (nbox[2]*pwidth))^2 +
                                              (0 - (nbox[3]*zstep))^2))
  
  # Bind positions in box with distances
  boxd <- cbind(null_box,d)
  
  # Fix problems with rounding tolerance
  boxd$x <- as.integer(boxd$x)
  boxd$y <- as.integer(boxd$y)
  boxd$z <- as.integer(boxd$z)
  
  # Bins of distances (microns)
  ds <- seq(0, size, by = dstep)
  
  # Load images
  ch1_files <- imgs[grep(channels[1], imgs)]
  ch2_files <- imgs[grep(channels[2], imgs)]
  
  # Progress bar
  pb <- txtProgressBar(max = length(ch1_files), style = 3)
  progress <- function(n) setTxtProgressBar(pb, n)
  opts <- list(progress = progress)
  
  # Start parallel
  if(cores == 1) {
    registerDoSEQ() 
  } else {
    cl <- makeCluster(cores)
    registerDoSNOW(cl)
  }
  
  cc_results <- foreach(i=1:length(ch1_files),.combine=rbind, .options.snow = opts) %dopar% {
    
    # Load
    ch1_t <- readRDS(ch1_files[i])
    ch2_t <- readRDS(ch2_files[i])
    
    # Subset
    if(!is.null(layers[[i]])){
      ch1_t <- ch1_t[,,layers[[i]]]
      ch2_t <- ch2_t[,,layers[[i]]]
    }
    
    # Smooth
    if(!is.null(kern.smooth)) {
      if(kern.smooth[1] %% 1 == 0 & kern.smooth[1] %% 2 != 0 &
         kern.smooth[2] %% 1 == 0 & kern.smooth[2] %% 2 != 0 &
         kern.smooth[3] %% 1 == 0 & kern.smooth[3] %% 2 != 0) {
        kern.s <- kernelArray(array(1,dim=kern.smooth))
        ch1_t <- medianFilter(ch1_t,kern.s)
        ch1_t[ch1_t > 0] <- 1
        ch2_t <- medianFilter(ch2_t,kern.s)
        ch2_t[ch2_t > 0] <- 1} else stop("Kernel smooth has to be odd integers in all directions")
    }
    
    # Sum channels
    sumch <- ch1_t+ch2_t
    
    # Densities of channels
    d1 <- length(which(ch1_t == 1))/length(ch1_t)
    d2 <- length(which(ch2_t == 1))/length(ch2_t)
    d12 <- length(which(sumch > 0))/length(sumch)
    
    # Addresses in array (pixels)
    address_array <- array(1:(dim(ch1_t)[1]*dim(ch1_t)[2]*dim(ch1_t)[3]), 
                           c(dim(ch1_t)[1], dim(ch1_t)[2], dim(ch1_t)[3]))
    
    # Coordinates of pixels in channel1 (pixels)
    ch1_add <- data.frame(which(ch1_t > 0, T))
    colnames(ch1_add) <- c("x", "y", "z")
    
    # Coordinates of pixels in channel2 (pixels)
    ch2_add <- data.frame(which(ch2_t > 0, T))
    colnames(ch2_add) <- c("x", "y", "z")
    
    # Coordinates of pixels in either channel (pixels)
    ch_sum <- data.frame(which(sumch > 0, T))
    colnames(ch_sum) <- c("x", "y", "z")
    
    # Randomly sample pixels (pixels)
    these <- sample(1:dim(ch_sum)[1], size = npixel)
    
    # Get their addresses
    ch_pix <- ch_sum[these,]
    
    # Matrix to collect results
    hits <- matrix(NA, length(ds), npixel)
    totals <- matrix(NA, length(ds), npixel)

    # Loop through pixels
    for(j in 1:npixel){
      
      # Focal pixel position
      p <- ch_pix[j,]

      # What colour is the focal pixel
      test1 <- ch1_add[ch1_add$x == p$x & ch1_add$y == p$y & ch1_add$z == p$z,]
      test2 <- ch2_add[ch2_add$x == p$x & ch2_add$y == p$y & ch2_add$z == p$z,]

      # Coordinates of the box (pixels)
      xrange <- c(p$x-(size/pwidth), p$x+(size/pwidth))
      yrange <- c(p$y-(size/pwidth), p$y+(size/pwidth))
      zrange <- c(p$z-(size/zstep), p$z+(size/zstep))
      
      # Edge handling
      xrange[xrange < 1] <- 1
      xrange[xrange > dim(address_array)[1]] <- dim(address_array)[1]
      
      yrange[yrange < 1] <- 1
      yrange[yrange > dim(address_array)[2]] <- dim(address_array)[2]
      
      zrange[zrange < 1] <- 1
      zrange[zrange > dim(address_array)[3]] <- dim(address_array)[3]
      
      # Addresses of the array (pixels)
      box <- address_array[c(xrange[1]:xrange[2]), 
                           c(yrange[1]:yrange[2]), 
                           c(zrange[1]:zrange[2])]  
      
      # New box for specific pixel (changes depending on position relative to the edges)
      new_box <- expand.grid(x = (seq(xrange[1], xrange[2], by = 1)-p$x), 
                             y = (seq(yrange[1], yrange[2], by = 1)-p$y), 
                             z = (seq(zrange[1], zrange[2], by = 1)-p$z))
      
      # Find distances to positions in new box
      new_d <- boxd[boxd$x %fin% new_box$x & boxd$y %fin% new_box$y & boxd$z %fin% new_box$z,"d"]
      
      # Presence absence data for the box (pixels)
      id1 <- ch1_t[box]
      id2 <- ch2_t[box]
      
      # Postitions of pixels
      positions <- list()
      for(p in 1:(length(ds))){
        positions[[p]] <- which(new_d <= ds[p]+dstep/2 & new_d > ds[p]-dstep/2)
      }
      
      # Hits and totals
      for(l in 1:(length(ds))){
          totals[l,j] <- length(which(id1[positions[[l]]]==0))+length(which(id1[positions[[l]]]==1))
          if(nrow(test1)==1 && nrow(test2)==0) hits[l,j] <- length(which(id2[positions[[l]]]==1))
          if(nrow(test2)==1 && nrow(test1)==0) hits[l,j] <- length(which(id1[positions[[l]]]==1))
          if(nrow(test1)==1 && nrow(test2)==1) hits[l,j] <- length(which(id1[positions[[l]]]==1))+length(which(id2[positions[[l]]]==1))      
      }
      
    }
    
    # Sum totals and hits for all pixels
    totals.sum <- apply(totals,1,sum,na.rm=T)
    hits.sum <- apply(hits,1,sum,na.rm=T)
    
    # Calculate probability and co-aggregation
    Prop <- hits.sum/totals.sum
    CA <- Prop/(2*(d1*d2/d12))

    theseCC <- cbind(gsub(channels[1],"",sub(".*/", "", ch1_files[i])),ds, CA)
    theseCC <- as.data.frame(theseCC)
    colnames(theseCC) <- c("Img", "Distance", "CA")
    return(theseCC)
  }
  if(cores != 1) stopCluster(cl)
  
  # Final polishing
  colnames(cc_results) <- c("Img", "Distance", "CA")
  cc_results$CA <- as.numeric(as.character(cc_results$CA))
  cc_results$Distance <- as.numeric(as.character(cc_results$Distance))
  
  cc_results$Pair <- paste(channels[1],"+",channels[2])
  
  if(!is.null(naming)){
    cc_resultsx <- cc_results
    for(i in 1:length(naming)){
      name.temp <- naming[[i]]
      cc_resultsx <- cbind(cc_resultsx,NA)
      for(j in 1:length(name.temp)){
        cc_resultsx[grep(name.temp[j],cc_resultsx$Img),ncol(cc_results)+i] <- name.temp[j]
      }
    }
    
    colnames(cc_resultsx) <- c(colnames(cc_results),names(naming))
    
  } else cc_resultsx <- cc_results
  
  
  return(cc_resultsx)
  
}
