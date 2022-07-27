{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NamedFieldPuns #-}

module Cardano.CLI.Faucet.Utils where

import Cardano.Prelude
import Cardano.Api (TxIn, TxOut(TxOut), CtxUTxO, Lovelace, CardanoEra, TxFee, txFeesExplicitInEra, TxFee(TxFeeImplicit, TxFeeExplicit), anyCardanoEra, TxValidityLowerBound(TxValidityNoLowerBound), TxValidityUpperBound(TxValidityNoUpperBound), validityNoUpperBoundSupportedInEra)
import Cardano.CLI.Faucet.Types
import Cardano.CLI.Faucet.Misc
import Control.Concurrent.STM (TMVar, takeTMVar, putTMVar)
import Data.Map.Strict qualified as Map
import Control.Monad.Trans.Except.Extra (left)
import Cardano.CLI.Shelley.Run.Transaction


computeUtxoStats :: Map TxIn (TxOut CtxUTxO era) -> UtxoStats
computeUtxoStats utxo = do
  let
    convertValue :: TxOut ctx era -> [FaucetValue]
    -- TODO, also report tokens in this list/type
    convertValue (TxOut _ value _ _) = [ getValue value ]
    folder :: UtxoStats -> FaucetValue -> UtxoStats
    folder (UtxoStats m) v = UtxoStats $ Map.insert v ((fromMaybe 0 $ Map.lookup v m) + 1) m
  foldl' folder (UtxoStats mempty) $ concat $ map convertValue $ Map.elems utxo

takeOneUtxo :: TMVar (Map TxIn (TxOut ctx era)) -> FaucetValue -> STM (Maybe (TxIn, TxOut ctx era))
takeOneUtxo utxoTMVar value = do
  utxo <- takeTMVar utxoTMVar
  let
    unwrap :: TxOut ctx1 era1 -> FaucetValue
    unwrap (TxOut _ val _ _) = getValue val
    utxoOfRightSize = Map.filter (\out -> unwrap out == value) utxo
    mTxin = head $ Map.toList $ Map.take 1 utxoOfRightSize
  case mTxin of
    Just (txin, txout) -> do
      let
        trimmedUtxo = Map.delete txin utxo
      putTMVar utxoTMVar trimmedUtxo
      pure $ Just (txin, txout)
    Nothing -> do
      putTMVar utxoTMVar utxo
      pure Nothing

findUtxoOfSize :: TMVar (Map TxIn (TxOut CtxUTxO era)) -> FaucetValue -> ExceptT FaucetWebError IO (TxIn, TxOut CtxUTxO era)
findUtxoOfSize utxoTMVar value = do
  mTxinout <- liftIO $ atomically $ takeOneUtxo utxoTMVar value
  case mTxinout of
    Just txinout -> pure txinout
    Nothing -> left $ FaucetWebErrorUtxoNotFound

validateTxFee ::
     CardanoEra era
  -> Maybe Lovelace
  -> ExceptT FaucetWebError IO (TxFee era)
validateTxFee era mfee = case (txFeesExplicitInEra era, mfee) of
  (Left  implicit, Nothing)  -> return (TxFeeImplicit implicit)
  (Right explicit, Just fee) -> return (TxFeeExplicit explicit fee)
  (Right _, Nothing) -> txFeatureMismatch era TxFeatureImplicitFees
  (Left  _, Just _)  -> txFeatureMismatch era TxFeatureExplicitFees

txFeatureMismatch ::
     CardanoEra era
  -> TxFeature
  -> ExceptT FaucetWebError IO a
txFeatureMismatch era feature = left (FaucetWebErrorFeatureMismatch (anyCardanoEra era) (show feature))

noBoundsIfSupported ::
     CardanoEra era
  -> ExceptT FaucetWebError IO (TxValidityLowerBound era, TxValidityUpperBound era)
noBoundsIfSupported era = (,)
  <$> pure TxValidityNoLowerBound
  <*> noUpperBoundIfSupported era

noUpperBoundIfSupported ::
     CardanoEra era
  -> ExceptT FaucetWebError IO (TxValidityUpperBound era)
noUpperBoundIfSupported era = case validityNoUpperBoundSupportedInEra era of
  Nothing -> txFeatureMismatch era TxFeatureValidityNoUpperBound
  Just supported -> return (TxValidityNoUpperBound supported)
