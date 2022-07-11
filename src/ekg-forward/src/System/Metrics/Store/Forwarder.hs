{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}

module System.Metrics.Store.Forwarder
  ( mkResponse
  ) where

import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as NE
import           Data.Maybe (mapMaybe)
import qualified System.Metrics as EKG

import           System.Metrics.Configuration (ForwarderConfiguration (..))
import           System.Metrics.ReqResp (MetricName, MetricValue (..),
                                         Request (..), Response (..)) 
import qualified System.Metrics.Protocol.Forwarder as Forwarder

mkResponse
  :: ForwarderConfiguration
  -> EKG.Store
  -> Forwarder.EKGForwarder Request Response IO ()
mkResponse config@ForwarderConfiguration{..} ekgStore =
  Forwarder.EKGForwarder
    { Forwarder.recvMsgReq = \request -> do
        actionOnRequest request
        allMetrics <- HM.toList <$> EKG.sampleAll ekgStore
        case request of
          GetAllMetrics -> do
            let supportedMetrics = mapMaybe filterMetrics allMetrics
            return ( ResponseMetrics supportedMetrics
                   , mkResponse config ekgStore
                   )
          GetMetrics (NE.toList -> mNames) -> do
            let metricsWeNeed = mapMaybe (filterMetricsWeNeed mNames) allMetrics
            return ( ResponseMetrics metricsWeNeed
                   , mkResponse config ekgStore
                   )
    , Forwarder.recvMsgDone = return ()
    }

filterMetrics
  :: (MetricName, EKG.Value)
  -> Maybe (MetricName, MetricValue)
filterMetrics (mName, ekgValue) =
  case ekgValue of
    EKG.Distribution _ -> Nothing  -- Distribution does not supported yet.
    EKG.Counter c      -> Just (mName, CounterValue c)
    EKG.Gauge g        -> Just (mName, GaugeValue g)
    EKG.Label l        -> Just (mName, LabelValue l)

filterMetricsWeNeed
  :: [MetricName]
  -> (MetricName, EKG.Value)
  -> Maybe (MetricName, MetricValue)
filterMetricsWeNeed mNames (mName, ekgValue) =
  case ekgValue of
    EKG.Distribution _ -> Nothing  -- Distribution does not supported yet.
    EKG.Counter c      -> onlyIfNeeded $ CounterValue c
    EKG.Gauge g        -> onlyIfNeeded $ GaugeValue g
    EKG.Label l        -> onlyIfNeeded $ LabelValue l
 where
  onlyIfNeeded value =
    if mName `elem` mNames then Just (mName, value) else Nothing
