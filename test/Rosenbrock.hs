import Model.Rosenbrock
import NestedSampling.Sampler
import System.Random.MWC hiding (initialize)

main :: IO ()
main = withSystemRandom . asGenIO $ \gen -> do

    -- Set the properties of the run you want to do
    let numParticles  = 1000    :: Int
        mcmcSteps     = 1000    :: Int
        maxDepth      = 80.0    :: Double
        numIterations = floor $ maxDepth * (fromIntegral numParticles) :: Int

    -- Create the sampler
    origin <- initialize
                numParticles mcmcSteps fromPrior logLikelihood perturb gen

    -- Do NS iterations until maxDepth is reached
    _ <- nestedSampling numIterations origin gen

    return ()
