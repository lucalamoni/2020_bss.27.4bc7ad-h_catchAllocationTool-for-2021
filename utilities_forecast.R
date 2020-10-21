# Function to optimis fleet Fmults to take the specified catches
# When optimising fmults, repress is set to TRUE

# Objective function for optimising fmults (sum of squares)
objective_func <- function(log_fmults, gearcatch, data, M, Frec, disSel, disProp, pop) {
  gC <-
    gearCatches(
      fmults = log_fmults, dat = data, pop = pop, Frec = Frec,
      disSel = disSel, disProp = disProp, M = M, repress = TRUE
    )

  sum((cG - gearcatch)^2)
}




runForecast <-
  function(
           months, selectivity_age, weights_age, M,
           pop_age_2020, f_age_rec_2020,
           f_age_rec_2020_month,
           discard_prop, discard_Sel, catches,
           Monthly, ICESadvComm, ICESadv,
           Myr, CatchGear, recCatch, catchRec_n,
           FbarRec, ICESadvOpt, AdviceForecastCatchAge, noVessels) {

    ##### -------------------------
    ### Prepare data objects
    dat <-
      selectivity_age %>%
      left_join(weights_age) %>%
      # left_join(pop_age_2020) %>%
      mutate(M = M) # %>%
    # left_join(f_age_rec_2020)

    # Gear types
    gears <- unique(selectivity_age$gear)

    # Population matrix (Jan 2020 to Jan 2021)
    initPop <- matrix(NA, 17, 13, dimnames = list(c(0:15, "16+"), months))
    initPop[, 1] <- pop_age_2020[, "N"]

    ##### -------------------------
    ### Monthly forecast
    if (Monthly) {

      # list to store results
      out <- list()
      # Switch for whether there is quota left or not (starts T, changes to F when quota used up. Rest of the months then have zero comm catch)
      switch <- TRUE

      for (i in 1:(length(months) - 1)) {
        # check how much of TAC has been taken
        if (switch) {
          caught <- 0
          if (i > 1) for (ii in 1:(i - 1)) caught <- caught + sum(out[[ii]]$gearCatches)
          remaining <- ICESadvComm - caught
          if (remaining < sum(catches[i, ])) {
            catches[i, ] <- catches[i, ] * (remaining / sum(catches[i, ]))
            if (i != (length(months) - 1)) for (ii in (i + 1):(length(months) - 1)) catches[ii, ] <- 0
            switch <- F
          }
        } # end of switch loop

        # Split catches in landings and discards
        lanDis <- c(as.numeric(catches[i, ]) * (1 - discard_prop[, 2]), sum(as.numeric(catches[i, ]) * discard_prop[, 2]))

        # optimise Fmults to take the catches specified
        opt <- optim(rep(0, length(lanDis)),
          objective_func,
          gearcatch = lanDis,
          data = dat,
          M = M,
          Frec = f_age_rec_2020_month,
          disSel = discard_Sel[, 2],
          disProp = discard_prop,
          pop = initPop[, months[i]],
          lower = rep(0, length(lanDis)),
          method = "L-BFGS-B"
        )
        fmults <- opt$par

        # Use optimised fmults to get catch.n, commercial F and total Z
        tmp <- gearCatches(fmults, dat, initPop[, i], f_age_rec_2020_month, disSel = discard_Sel[, 2], disProp = discard_prop, M = M, repress = FALSE)
        # # Get recreational catch at age and total catch

        # Project population forward one month
        # Note, ages unchanged, for Jan2021 shifted one age older after this loop
        initPop[, i + 1] <- initPop[, i] * exp(-tmp$total_z)

        # Save monthly results in list
        out[[i]] <- tmp
      } # end of loop over months
    } # END of Monthly simulation

    ##### -------------------------
    ### Annual forecast
    if (!Monthly) {
      # list to store results
      out <- list()

      # Cap catches at ICES advice
      if (ICESadvComm < sum(catches[1, ])) catches[1, ] <- catches[1, ] * (ICESadvComm / sum(catches[1, ]))

      # Split catches in landings and discards
      lanDis <- c(as.numeric(catches[1, ]) * (1 - discard_prop[, 2]), sum(as.numeric(catches[1, ]) * discard_prop[, 2]))

      # optimise Fmults to take the catches specified
      opt <- optim(rep(0, length(lanDis)),
        objective_func,
        gearcatch = lanDis,
        data = dat,
        M = Myr,
        Frec = f_age_rec_2020,
        disSel = discard_Sel[, 2],
        disProp = discard_prop,
        pop = initPop[, 1],
        lower = rep(0, length(lanDis)),
        # upper= rep(100, length(lanDis)),
        method = "L-BFGS-B"
      )
      fmults <- opt$par

      # Use optimised fmults to get catch.n, commercial F and total Z
      tmp <- gearCatches(fmults = fmults, dat = dat, pop = initPop[, 1], Frec = f_age_rec_2020, disSel = discard_Sel[, 2], disProp = discard_prop, M = Myr, repress = FALSE)
      # # Get recreational catch at age and total catch

      # Project population forward one month
      # Note, ages unchanged, for Jan2021 shifted one age older after this loop
      initPop[, 13] <- initPop[, 1] * exp(-tmp$total_z)

      # Save monthly results in list
      out[[1]] <- tmp
    } # END of Annual simulation



    ##### -------------------------
    ### Sort results

    ## Commercial catches

    # Commercial Landings
    realisedLandings <- catches
    realisedLandings[] <- 0
    if (Monthly) {
      for (i in 1:(length(months) - 1)) {
        realisedLandings[i, ] <- out[[i]]$gearCatches[, 1:length(gears)]
      }
      realisedLandings[13, ] <- apply(realisedLandings[-13, ], 2, sum)
    } else {
      realisedLandings[13, ] <- out[[1]]$gearCatches[, 1:length(gears)]
    }
    totCommLandings <- sum(realisedLandings[13, ])

    # Commercial Discards
    realisedDiscards <- catches
    realisedDiscards[] <- 0
    if (Monthly) {
      for (i in 1:(length(months) - 1)) {
        if (sum(realisedLandings[i, ]) != 0) {
          activeDisProp <- discard_prop
          activeDisProp[, 2] <- as.numeric(discard_prop[, 2] * realisedLandings[i, ]) / sum(realisedLandings[i, ])
          realisedDiscards[i, ] <- (out[[i]]$gearCatches[, (length(gears) + 1)] * activeDisProp[, 2]) / sum(activeDisProp[, 2])
        } else {
          realisedDiscards[i, ] <- rep(0, length(gears))
        }
      }
      realisedDiscards[13, ] <- apply(realisedDiscards[-13, ], 2, sum)
    } else {
      if (sum(realisedLandings[13, ]) != 0) {
        activeDisProp <- discard_prop
        activeDisProp[, 2] <- as.numeric(discard_prop[, 2] * realisedLandings[13, ]) / sum(realisedLandings[13, ])
        realisedDiscards[13, ] <- (out[[1]]$gearCatches[, (length(gears) + 1)] * activeDisProp[, 2]) / sum(activeDisProp[, 2])
      } else {
        realisedDiscards[13, ] <- rep(0, length(gears))
      }
    }
    totCommDiscards <- sum(realisedDiscards[13, ])
    # Commercial Catch
    realisedCatch <- realisedLandings + realisedDiscards
    totCommCatch <- sum(realisedCatch[13, ])

    # to make perfect with advice
    if (Monthly) {
      ft <- sum(catches[13, ], na.rm = TRUE) > ICESadvComm
    } else {
      ft <- sum(catches[1, ], na.rm = TRUE) > ICESadvComm
    }
    if (ft) {
      adj <- ICESadvComm / totCommCatch
      totCommCatch <- ICESadvComm
      totCommLandings <- adj * totCommLandings
      totCommDiscards <- adj * totCommDiscards
    }

    ## Catch at age
    catch_n <- out[[1]]$catch_n
    if (Monthly) for (i in 2:(length(months) - 1)) catch_n <- catch_n + out[[i]]$catch_n
    catch_n <- cbind(catch_n, catchRec_n)
    dimnames(catch_n)[[2]][length(gears) + 1] <- "Recreational"

    ### F values
    ## Total
    if (!Monthly) {
      totalF <- out[[1]]$total_z - Myr
    }
    if (Monthly) {
      totalF <- out[[1]]$total_z - M
      for (i in 2:(length(months) - 1)) totalF <- totalF + out[[i]]$total_z - M
    }
    Ftotbar <- mean(totalF[5:16]) # ages 4-15
    if (Ftotbar < 0.2) Ftotbar <- round(Ftotbar, 3) else Ftotbar <- round(Ftotbar, 2)

    ## Commercial F and Fbar
    catchF <- out[[1]]$catch_f
    if (Monthly) {
      for (i in 2:(length(months) - 1)) {
        catchF <- catchF + out[[i]]$catch_f
      }
    }
    Fcomm <- apply(catchF, 1, sum) # F landings + discards
    Fcommbar <- mean(Fcomm[5:16]) # ages 4-15
    # ICES rounding
    if (Fcommbar < 0.2) {
      Fcommbar <- round(Fcommbar, 3)
    } else {
      Fcommbar <- round(Fcommbar, 2)
    }
    ## By gear
    gearFTable <- apply(catchF[5:16, ], 2, mean)
    for (gg in gears) {
      if (gearFTable[gg] < 0.2) {
        gearFTable[gg] <- round(gearFTable[gg], 3)
      } else {
        gearFTable[gg] <- round(gearFTable[gg], 2)
      }
    }

    ## Landings
    landF <- out[[1]]$land_f
    if (Monthly) {
      for (i in 2:(length(months) - 1)) {
        landF <- landF + out[[i]]$land_f
      }
    }
    Fland <- apply(landF, 1, sum) # F landings
    Flandbar <- mean(Fland[5:16]) # ages 4-15
    # ICES rounding
    if (Flandbar < 0.2) {
      Flandbar <- round(Flandbar, 3)
    } else {
      Flandbar <- round(Flandbar, 2)
    }

    ## Discards
    discF <- out[[1]]$dis_f
    if (Monthly) {
      for (i in 2:(length(months) - 1)) {
        discF <- discF + out[[i]]$dis_f
      }
    }
    Fdis <- discF
    Fdisbar <- mean(Fdis[5:16]) # ages 4-15
    # ICES rounding
    if (Fdisbar < 0.2) {
      Fdisbar <- round(Fdisbar, 3)
    } else {
      Fdisbar <- round(Fdisbar, 2)
    }

    ## Annual recreational catch and F
    # recCatch
    if (FbarRec < 0.2) {
      FbarRec <- round(FbarRec, 3)
    } else {
      FbarRec <- round(FbarRec, 2)
    }

    # Catch including recreational
    realisedCatch <- cbind(realisedCatch, realisedCatch[, 1])
    realisedCatch[, length(gears) + 1] <- NA
    dimnames(realisedCatch)[[2]][length(gears) + 1] <- "Recreational"
    realisedCatch[13, length(gears) + 1] <- recCatch
    realisedCatch[, 1:length(gears)] <- adj * realisedCatch[, 1:length(gears)]
    # round the values (have many decimals due to optimising Fmults)
    totalCatch <- sum(realisedCatch[13, ], na.rm = T)

    # Change ages for Jan 2021
    initPop[nrow(initPop), 13] <- initPop[nrow(initPop), 13] + initPop[nrow(initPop) - 1, 13]
    initPop[1:(nrow(initPop) - 1), 13] <- c(0, initPop[1:(nrow(initPop) - 2), 13])

    # SSB 2021
    ssb2021 <- sum(initPop[, 13] * mat * stkwt)






    ##### -------------------------
    ### Show outputs

    ## Catch y gear table
    CatchGearTable <- as.matrix(realisedCatch)
    CatchGearTable <- rbind(CatchGearTable, c(gearFTable, NA))
    CatchGearTable <- cbind(CatchGearTable, rep(NA, nrow(CatchGearTable)))
    dimnames(CatchGearTable = )[[1]] <- c(months[1:12], "TOTAL", "F")
    dimnames(CatchGearTable)[[2]][ncol(CatchGearTable)] <- "TOTAL"

    # F by gear
    CatchGearTable["F", "Recreational"] <- FbarRec

    # Add total column
    CatchGearTable[, "TOTAL"] <- apply(CatchGearTable[, 1:(length(gears) + 1)], 1, sum, na.rm = T)
    CatchGearTable["F", "TOTAL"] <- Ftotbar # to account for rounding errors
    # Round
    CatchGearTable[-nrow(CatchGearTable), ] <- round(CatchGearTable[-nrow(CatchGearTable), ], 0)
    # Add months
    CatchGearTable <- cbind(rep(NA, nrow(CatchGearTable)), CatchGearTable)
    dimnames(CatchGearTable)[[2]][1] <- "Month"
    CatchGearTable[, "Month"] <- c(months[1:12], "TOTAL", "F")

    ## Catch gear table as VCLS
    vclsGearTable <- CatchGearTable[-nrow(CatchGearTable), c("Month", as.character(gears))]
    for (ii in 1:(nrow(catches))) {
      vclsGearTable[ii, -1] <- round(as.numeric(vclsGearTable[ii, -1]) / noVessels[, 2], 1)
    }
    vclsGearTable[nrow(catches), 1] <- "Annual catch/vessel"





    ## Catch at age plot
    dataPlot <- as.data.frame(selectivity_age)
    dataPlot <- rbind(dataPlot[1:34, ], dataPlot)
    levels(dataPlot$gear) <- c(levels(dataPlot$gear), "Recreational", "AdviceForecast")
    dimnames(dataPlot)[[2]][2] <- "catch_n"
    dataPlot[1:17, "gear"] <- "AdviceForecast"
    dataPlot[18:34, "gear"] <- "Recreational"
    for (gg in c(as.character(gears), "Recreational")) dataPlot[dataPlot$gear == gg, ]$catch_n <- catch_n[, gg]
    if (ICESadvOpt == "MSY") expected <- AdviceForecastCatchAge[, "MSY"] else expected <- AdviceForecastCatchAge[, "MSYlow"]
    dataPlot[dataPlot$gear == "AdviceForecast", ]$catch_n <- expected
    dataPlot$gear <- gsub("_", " ", dataPlot$gear)

    p <-
      ggplot() +
      geom_area(
        data = subset(dataPlot, gear != "AdviceForecast"), position = "stack",
        aes(x = Age, y = catch_n, fill = gear)
      ) +
      geom_line(
        data = subset(dataPlot, gear == "AdviceForecast"), linetype = 2,
        aes(x = Age, y = catch_n)
      ) +
      ylab("Catch-at-Age (thousands)") +
      theme(plot.background = element_rect(fill = "grey96")) +
      theme(legend.background = element_rect(fill = "grey96", size = 0.5, linetype = "solid")) +
      theme(panel.background = element_rect(fill = "grey96"))





    ## Forecast table outputs
    forecastTable <- matrix(NA, ncol = 12, nrow = 1, dimnames = list(
      ICESadvOpt,
      c(
        "Basis", "Total Catch", "Commercial Landings", "Commercial discards", "Recreational removals", "Total F", "F Commercial landings",
        "F Commercial discards", "F Recreational removals", "SSB (2021)", "% SSB change", "% Advice change"
      )
    ))
    forecastTable[, "Basis"] <- "Simulated Scenario"
    forecastTable[, "Total Catch"] <- round(totCommCatch + recCatch, 0)
    forecastTable[, "Commercial Landings"] <- round(totCommLandings, 0)
    forecastTable[, "Commercial discards"] <- round(totCommDiscards, 0)
    forecastTable[, "Recreational removals"] <- round(recCatch, 0)
    forecastTable[, "Total F"] <- Ftotbar
    forecastTable[, "F Commercial landings"] <- Flandbar
    forecastTable[, "F Commercial discards"] <- Fdisbar
    forecastTable[, "F Recreational removals"] <- FbarRec
    forecastTable[, "SSB (2021)"] <- round(ssb2021, 0)
    forecastTable[, "% SSB change"] <- round(100 * (ssb2021 - 11413) / 11413, 1) # DM: change from fixed value
    if (ft) {
      if (ICESadvOpt == "MSY") forecastTable[, "% Advice change"] <- 7.8 else forecastTable[, "% Advice change"] <- -9.5
    }
    if (!ft) forecastTable[, "% Advice change"] <- round(100 * ((totCommCatch + recCatch) - 1806) / 1806, 1) # DM: change from fixed value

    # 2019 Advice sheet catch scenarios
    forecastTable <- rbind(forecastTable, forecastTable, forecastTable)
    for (i in 2:3) for (j in 1:ncol(forecastTable)) forecastTable[i, j] <- as.character(AdviceScenarios[i - 1, j])

    # Add spaces instead of _ in names
    dimnames(CatchGearTable)[[2]] <- gsub("_", " ", dimnames(CatchGearTable)[[2]])
    dimnames(vclsGearTable)[[2]] <- gsub("_", " ", dimnames(vclsGearTable)[[2]])
    forecastTable[, "Basis"] <- gsub("_", " ", forecastTable[, "Basis"])


    list(
      catchNplot = p,
      CatchGearTable = CatchGearTable,
      forecastTable = forecastTable,
      vclsGearTable = vclsGearTable
    )
  }