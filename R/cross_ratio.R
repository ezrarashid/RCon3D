#' 3D cross-ratio
#'
#' Function to calculate 3D cross-ratio between three channels. The ratio is between first and second target channel at the distance from the focal channel.
#' @param imgs The paths of array files; i.e. output from \code{loadIMG} or \code{findIMG} functions.
#' @param focal.channel Character of name of channel of focus.
#' @param target.channels Character vector with names of the two target channels to calculate cross-ratio between
#' @param size The maximum distance (microns) to examine. Has to be a multiple of both pwidth and zstep. Beware, increasing size will increase runtime exponetially!
#' @param npixel Number of random pixels to examine. Increasing this will increase precision (and runtime in a linear fashion)
#' @param R Number of times to run the cross-ratio analysis
#' @param dstep The interval between examined distances (microns). Increasing this decreases resolution but speeds up function linearly. Defaults to 1
#' @param pwidth Width of pixels in microns
#' @param zstep z-step in microns
#' @param cores The number of cores to use.Defaults to 1
#' @param kern.smooth Optional. Numeric vector indicating range of median smoothing in the x,y,z directions. Has to be odd intergers. c(1,1,1) means no smoothing.
#' @param layers Optional. Should the function only look in a subset of layers. A list with lists of layers to use for each image. Can also be the output from \code{extract_layers} 
#' @param naming Optional. Add metadata to the output dataframe by looking through names of array files. Should be a list of character vectors, each list element will be added as a variable. Example: naming=list(Time=c("T0","T1","T2")). The function inserts a variable called Time, and then looks through the names of the array files and inserts characters mathcing either T0, T1 or T2
#' @keywords array image cross-ratio
#' @return A dataframe with the cross-ratio values for each distance
#' @import doSNOW
#' @import parallel
#' @import foreach
#' @import fastmatch
#' @export

cross_ratio <- function(imgs,focal.channel,target.channels,size,npixel,R=10,dstep=1,pwidth,zstep,cores=1,kern.smooth=NULL,layers=NULL,naming=NULL){
  
  if(size%%zstep != 0) if(all.equal(size%%zstep,zstep)!=TRUE) stop("size not a multiple of zstep")
  if(size%%pwidth != 0) if(all.equal(size%%pwidth,pwidth)!=TRUE) stop("size not a multiple of pwidth")
  
  stopifnot(length(target.channels)==2,
            length(focal.channel)==1)
  
  CR.all <- list()
  for(r in 1:R){
    message(paste("Starting run "),r)
    CR <- cross_ratio.default(imgs,focal.channel,target.channels,size,npixel,dstep,pwidth,zstep,cores,kern.smooth,layers,naming)
    CR$R <- r
    CR.all[[r]] <- CR
  }
  CRall <- do.call("rbind", CR.all)

  return(CRall)
}

#' @rdname cross_ratio
#' @export

cross_ratio.default <- function(imgs,focal.channel,target.channels,size,npixel,dstep=1,pwidth,zstep,cores=1,kern.smooth=NULL,layers=NULL,naming=NULL) {

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
  ch.t1_files <- imgs[grep(target.channels[1], imgs)]
  ch.t2_files <- imgs[grep(target.channels[2], imgs)]
  ch.f_files <- imgs[grep(focal.channel, imgs)]
  
  # Progress bar
  pb <- txtProgressBar(max = length(ch.t1_files), style = 3)
  progress <- function(n) setTxtProgressBar(pb, n)
  opts <- list(progress = progress)
  
  # Start parallel
  if(cores == 1) {
    registerDoSEQ() 
  } else {
    cl <- makeCluster(cores)
    registerDoSNOW(cl)
  }
  
  cr_results <- foreach(i=1:length(ch.t1_files),.combine=rbind, .options.snow = opts) %dopar% {
    
    # Load
    ch.t1 <- readRDS(ch.t1_files[i])
    ch.t2 <- readRDS(ch.t2_files[i])
    ch.f <- readRDS(ch.f_files[i])
    
    # Subset
    if(!is.null(layers[[i]])){
      ch.t1 <- ch.t1[,,layers[[i]]]
      ch.t2 <- ch.t2[,,layers[[i]]]
      ch.f <- ch.f[,,layers[[i]]]
    }
    
    # Smooth
    if(!is.null(kern.smooth)) {
      if(kern.smooth[1] %% 1 == 0 & kern.smooth[1] %% 2 != 0 &
         kern.smooth[2] %% 1 == 0 & kern.smooth[2] %% 2 != 0 &
         kern.smooth[3] %% 1 == 0 & kern.smooth[3] %% 2 != 0) {
        kern.s <- kernelArray(array(1,dim=kern.smooth))
        ch.t1 <- medianFilter(ch.t1,kern.s)
        ch.t1[ch.t1 > 0] <- 1
        ch.t2 <- medianFilter(ch.t2,kern.s)
        ch.t2[ch.t2 > 0] <- 1
        ch.f <- medianFilter(ch.f,kern.s)
        ch.f[ch.f > 0] <- 1} else stop("Kernel smooth has to be odd integers in all directions")
    }

    # Densities of channels
    d1 <- length(which(ch.t1 == 1))/length(ch.t1)
    d2 <- length(which(ch.t2 == 1))/length(ch.t2)

    # Addresses in array (pixels)
    address_array <- array(1:(dim(ch.t1)[1]*dim(ch.t1)[2]*dim(ch.t1)[3]), 
                           c(dim(ch.t1)[1], dim(ch.t1)[2], dim(ch.t1)[3]))

    # Coordinates of pixels in focal channel (pixels)
    chf_add <- data.frame(which(ch.f == 1, T))
    colnames(chf_add) <- c("x", "y", "z")
   
    # Randomly sample pixels (pixels)
    these <- sample(1:dim(chf_add)[1], size = npixel)
    
    # Get their addresses
    ch_pix <- chf_add[these,]
    
    # Matrix to collect results
    hits1 <- matrix(NA, length(ds), npixel)
    hits2 <- matrix(NA, length(ds), npixel)
    
    # Loop through pixels
    for(j in 1:npixel){
      
      # Focal pixel position
      p <- ch_pix[j,]
      
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
      id1 <- ch.t1[box]
      id2 <- ch.t2[box]
      
      # Postitions of pixels
      positions <- list()
      for(p in 1:(length(ds))){
        positions[[p]] <- which(new_d <= ds[p]+dstep/2 & new_d > ds[p]-dstep/2)
      }
      
      # Count hits
      for(l in 1:(length(ds))){
        hits1[l,j] <- length(which(id1[positions[[l]]]==1))
        hits2[l,j] <- length(which(id2[positions[[l]]]==1))

      }
    }
    
    # Sum hits for all pixels
    hits1.sum <- apply(hits1,1,sum,na.rm=T)
    hits2.sum <- apply(hits2,1,sum,na.rm=T)
    
    # Calculate ratio and cross-ratio
    Ratio <- hits1.sum/hits2.sum
    CR <- Ratio/(d1/d2)

    theseCR <- cbind(gsub(target.channels[1],"",sub(".*/", "", ch.t1_files[i])),ds, CR)
    theseCR <- as.data.frame(theseCR)
    colnames(theseCR) <- c("Img","Distance", "CR")
    
    return(theseCR)
    
  }
  if(cores != 1) stopCluster(cl)
  
  # Final polishing
  colnames(cr_results) <- c("Img", "Distance", "CR")
  cr_results$CR <- as.numeric(as.character(cr_results$CR))
  cr_results$Distance <- as.numeric(as.character(cr_results$Distance))
  
  cr_results$Targets <- paste(target.channels[1],"/",target.channels[2])
  cr_results$Focal <- focal.channel
  
  if(!is.null(naming)){
    cr_resultsx <- cr_results
    for(i in 1:length(naming)){
      name.temp <- naming[[i]]
      cr_resultsx <- cbind(cr_resultsx,NA)
      for(j in 1:length(name.temp)){
        cr_resultsx[grep(name.temp[j],cr_resultsx$Img),ncol(cr_results)+i] <- name.temp[j]
      }
    }
    
    colnames(cr_resultsx) <- c(colnames(cr_results),names(naming))
    
  } else cr_resultsx <- cr_results
  
  
  return(cr_resultsx)
  
}