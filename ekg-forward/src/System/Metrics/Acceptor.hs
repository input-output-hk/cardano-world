{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This top-level module will be used by the acceptor app
-- (the app that asks EKG metrics from the forwarder app).
module System.Metrics.Acceptor (
  runEKGAcceptor
  ) where

import           Control.Exception (SomeException, try)
import           Control.Monad (void)
import           Data.IORef (newIORef)
import qualified System.Metrics as EKG

import           System.Metrics.Network.Acceptor (listenToForwarder)
import           System.Metrics.Store.Acceptor (emptyMetricsLocalStore)
import           System.Metrics.Configuration (AcceptorConfiguration (..))

-- | Please note that acceptor is a server from the __networking__ point of view:
-- the forwarder establishes network connection with the acceptor.
runEKGAcceptor
  :: AcceptorConfiguration  -- ^ Acceptor configuration.
  -> EKG.Store              -- ^ The store all received metrics will be stored in.
  -> IO ()
runEKGAcceptor config ekgStore = do
  metricsStore <- newIORef emptyMetricsLocalStore
  try (void $ listenToForwarder config ekgStore metricsStore) >>= \case
    Left (_e :: SomeException) ->
      runEKGAcceptor config ekgStore
    Right _ -> return ()
