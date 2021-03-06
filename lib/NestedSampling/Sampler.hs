{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module NestedSampling.Sampler (
    -- * sampling functions
    initialize
  , nestedSampling

    -- * sampling types
  , Sampler(..)
  , Particles
  ) where

import Control.Monad
import Control.Monad.Primitive (RealWorld)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe
import Data.IntPSQ (IntPSQ)
import qualified Data.IntPSQ as PSQ
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Formatting
import NestedSampling.Logging
import NestedSampling.Model
import NestedSampling.Utils
import System.IO
import System.Random.MWC (Gen)
import qualified System.Random.MWC as MWC hiding (initialize)

-- Likelihood and tiebreaker
data Lltb = Lltb {-# UNPACK #-} !Double {-# UNPACK #-} !Double
  deriving (Eq, Ord)

-- The particles, arranged into a PSQ
type Particles a = IntPSQ Lltb a

-- Perturbation function for model type a
type Perturber a = a -> Gen RealWorld -> IO (Double, a)

data Sampler a = Sampler {
    samplerDim        :: {-# UNPACK #-} !Int
  , samplerSteps      :: {-# UNPACK #-} !Int
  , samplerLikelihood :: a -> Double
  , samplerPerturber  :: Perturber a
  , samplerParticles  :: !(Particles a)
  , samplerIter       :: {-# UNPACK #-} !Int
  , samplerLogZ       :: {-# UNPACK #-} !Double
  , samplerInfo       :: {-# UNPACK #-} !Double
  , samplerAccepts    :: {-# UNPACK #-} !Int    -- Metropolis acceptance count
  , samplerTries      :: {-# UNPACK #-} !Int    -- Metropolis attempts count
  }

instance Show (Sampler a) where
  show Sampler {..} = mconcat [
        "Iteration " ++ show samplerIter ++ ". "
      , "ln(X) = " ++ show (negate (k / n)) ++ ". "
      , "ln(L) = " ++ sllworst ++ ".\n"
      , "ln(Z) = " ++ show samplerLogZ ++ ", "
      , "H = " ++ show samplerInfo ++ " nats."
      ]
    where
      k = fromIntegral samplerIter
      n = fromIntegral samplerDim
      llworst = do
        (_, Lltb llw _, _) <- PSQ.findMin samplerParticles
        return llw

      sllworst = case llworst of
        Nothing -> "NA"
        Just p  -> show p

-- | Render a Sampler as a text value.
render :: Sampler a -> T.Text
render Sampler {..} =
    sformat
      (int % "," % float % "," % float % "," % string % "," % float % "," % float)
      samplerIter (negate (k / n)) logPriorWeight sllworst samplerLogZ samplerInfo
  where
    k = fromIntegral samplerIter
    n = fromIntegral samplerDim
    logPriorWeight = - k / n + log (exp (recip n) - 1.0)
    llworst = do
      (_, Lltb llw _, _) <- PSQ.findMin samplerParticles
      return llw

    sllworst = case llworst of
      Nothing -> "NA"
      Just p  -> show p

-- | Initialize a sampler with the provided dimension, number of steps, prior,
--   perturbation function, and log-likelihood.
initialize
  :: Int                            -- ^ Number of particles
  -> Int                            -- ^ Number of MCMC steps
  -> Model a                        -- ^ Model specification
  -> Gen RealWorld                  -- ^ PRNG
  -> IO (Sampler a)
initialize n m (Model {..}) gen = do
    particles <- replicateM samplerDim (modelFromPrior gen)
    tbs       <- replicateM samplerDim (MWC.uniform gen)

    let lls               = fmap modelLogLikelihood particles
        lltbs             = zipWith Lltb lls tbs
        samplerParticles  = PSQ.fromList (zip3 [0..] lltbs particles)
        samplerIter       = 1
        samplerLogZ       = -1E300
        samplerInfo       = 0
        samplerPerturber  = modelPerturb
        samplerLikelihood = modelLogLikelihood
        samplerAccepts    = 0
        samplerTries      = 0
    return Sampler {..}
  where
    samplerDim   = if n <= 1 then 1 else n
    samplerSteps = if m <= 0 then 0 else m

-- | Perform nested sampling for the specified number of iterations.
nestedSampling
  :: Show a
  => LoggingOptions -> Int -> Sampler a -> Gen RealWorld -> IO (Sampler a)
nestedSampling logopts = loop where
  loop n sampler gen
    | n <= 0    = return sampler
    | otherwise = do
        mnext <- runMaybeT $ nestedSamplingIteration logopts sampler gen
        case mnext of
          Nothing   -> error "nestedSamplingIterations: no particles found"
          Just next -> loop (n - 1) next gen
{-# INLINE nestedSampling #-}

-- | Perform a single nested sampling iteration.
nestedSamplingIteration
  :: Show a
  => LoggingOptions -> Sampler a -> Gen RealWorld -> MaybeT IO (Sampler a)
nestedSamplingIteration LoggingOptions {..} Sampler {..} gen = do
  (_, Lltb lworst _, worst) <- hoistMaybe (PSQ.findMin samplerParticles)
  (particles, accepts) <- updateParticles Sampler {..} gen

  let k = fromIntegral samplerIter
      n = fromIntegral samplerDim
      logPriorWeight = - k / n + log (exp (recip n) - 1.0)
      logPost        = logPriorWeight + lworst
      samplerLogZ'   = logsumexp samplerLogZ logPost
      samplerInfo'   =
          exp (logPost - samplerLogZ') * lworst
        + exp (samplerLogZ - samplerLogZ') * (samplerInfo + samplerLogZ)
        - samplerLogZ'

  -- Are we on an iteration where we'd print messages to stdout?
  let printing = samplerIter `mod` samplerDim == 0 :: Bool

  -- Saving stuff to file
  lift $ do
    when (samplerIter == 1) $ writeHeader LoggingOptions {..}
    let mode = if samplerIter `div` logThinning == 1
               then WriteMode
               else AppendMode
    when (samplerIter `mod` logThinning == 0) $
      writeToFile LoggingOptions {..} mode Sampler {..} worst

  -- Printing stuff to screen
  lift $ do
    when (logProgress && printing) $ print Sampler {..}
    let a    = samplerAccepts + accepts
        c    = samplerTries + samplerSteps
        aStr = show a
        cStr = show c
    when (logProgress && printing) $ putStrLn
            (mconcat ["Recent M-H acceptance rate = ", aStr, "/", cStr, ".\n"])

  return $! Sampler {
      samplerParticles = particles
    , samplerIter      = samplerIter + 1
    , samplerLogZ      = samplerLogZ'
    , samplerInfo      = samplerInfo'
    , samplerAccepts   = if printing then 0 else samplerAccepts + accepts
    , samplerTries     = if printing then 0 else samplerTries + samplerSteps
    , ..
    }
{-# INLINE nestedSamplingIteration #-}

updateParticles :: Sampler a -> Gen RealWorld -> MaybeT IO (Particles a, Int)
updateParticles Sampler {..} gen = do
  (iworst, lltbworst, _) <- hoistMaybe (PSQ.findMin samplerParticles)
  idx            <- lift (chooseCopy iworst samplerDim gen)
  (lltb, p)      <- hoistMaybe (PSQ.lookup idx samplerParticles)
  (lltb', p', c) <- lift $
    metropolisUpdates
      samplerSteps lltbworst (lltb, p, 0) samplerLikelihood samplerPerturber gen

  let replace mparticle = case mparticle of
        Just (j, _, _) -> ((), Just (j, lltb', p'))
        Nothing        -> ((), Nothing)

      (_, !updated) = PSQ.alterMin replace samplerParticles

  return (updated, c)
{-# INLINE updateParticles #-}


metropolisUpdates
  :: Int
  -> Lltb
  -> (Lltb, a, Int)     -- Stuff. Log likelihood and tiebreaker,
                        -- particle, accept count.
  -> (a -> Double)
  -> Perturber a
  -> Gen RealWorld
  -> IO (Lltb, a, Int)
metropolisUpdates = loop where
  loop n threshold stuff logLikelihood perturber gen
    | n <= 0    = return stuff
    | otherwise = do
        next <- metropolisUpdate threshold stuff logLikelihood perturber gen
        loop (n - 1) threshold next logLikelihood perturber gen
{-# INLINE metropolisUpdates #-}

metropolisUpdate
  :: Lltb
  -> (Lltb, a, Int) -- Stuff. Log likelihood and tiebreaker,
                    -- particle, accept count.
  -> (a -> Double)
  -> Perturber a
  -> Gen RealWorld
  -> IO (Lltb, a, Int)
metropolisUpdate (Lltb llThresh tbThresh) (Lltb ll tb, x, c)
                                        logLikelihood perturber gen = do
  (logH, proposal) <- perturber x gen
  let a = exp logH
  uu <- MWC.uniform gen
  let llProp = logLikelihood proposal

  -- Generate tiebreaker for proposal
  rh <- randh gen
  let !tbProp = wrap (tb + rh) (0.0, 1.0)

  -- Check whether proposal is above threshold
  let check1 = llProp > llThresh
      check2 = llProp == llThresh && tbProp > tbThresh

  let accept = (uu < a) && (check1 || check2)
  return $
    if   accept
    then (Lltb llProp tbProp, proposal, c + 1)
    else (Lltb ll tb, x, c)
{-# INLINE metropolisUpdate #-}

-- | Write the CSV header
writeHeader :: LoggingOptions -> IO ()
writeHeader LoggingOptions {..} = do
  case logSamplerFile of
    Nothing    -> return ()
    Just file  -> do
      sampleInfo <- openFile file WriteMode
      T.hPutStrLn sampleInfo "n,ln_x,ln_prior_weight,ln_l,ln_z,h"
      hClose sampleInfo
{-# INLINE writeHeader #-}

-- | Write sampler/particle information to disk.
writeToFile
  :: Show a
  => LoggingOptions -> IOMode -> Sampler a -> a -> IO ()
writeToFile LoggingOptions {..} mode sampler particle = do
  case logSamplerFile of
    Nothing   -> return ()
    Just file -> do
      -- Always append mode for the info file
      sampleInfo <- openFile file AppendMode
      T.hPutStrLn sampleInfo $ render sampler
      hClose sampleInfo

  case logParametersFile of
    Nothing   -> return ()
    Just file -> do
      sample <- openFile file mode
      hPutStrLn sample $
        filter (`notElem` ("fromList[]" :: String)) (show particle)
      hClose sample
{-# INLINE writeToFile #-}


