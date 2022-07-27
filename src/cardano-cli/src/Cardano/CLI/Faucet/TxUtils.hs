{-# LANGUAGE ImportQualifiedPost #-}

module Cardano.CLI.Faucet.TxUtils where

import Cardano.Api (ConsensusModeParams, CardanoMode, Lovelace(Lovelace), toEraInMode, ConsensusMode(CardanoMode), IsShelleyBasedEra, ShelleyBasedEra, NetworkId, TxIn, TxOut, CtxUTxO, TxBody, BalancedTxBody(BalancedTxBody), TxBodyContent(TxBodyContent), Witness(KeyWitness), LocalNodeConnectInfo(LocalNodeConnectInfo), KeyWitnessInCtx(KeyWitnessForSpending), TxInsCollateral(TxInsCollateralNone), TxInsReference(TxInsReferenceNone), TxTotalCollateral(TxTotalCollateralNone), TxReturnCollateral(TxReturnCollateralNone), TxMetadataInEra(TxMetadataNone), TxAuxScripts(TxAuxScriptsNone), TxExtraKeyWitnesses(TxExtraKeyWitnessesNone), TxWithdrawals(TxWithdrawalsNone), TxCertificates(TxCertificatesNone), BuildTxWith(BuildTxWith), TxUpdateProposal(TxUpdateProposalNone), TxMintValue(TxMintNone), TxScriptValidity(TxScriptValidityNone), shelleyBasedToCardanoEra, AnyConsensusMode(AnyConsensusMode), UTxO(UTxO), executeLocalStateQueryExpr, queryExpr, QueryInEra(QueryInShelleyBasedEra), QueryInShelleyBasedEra(QueryStakePools, QueryProtocolParameters), QueryInMode(QueryInEra, QueryEraHistory, QuerySystemStart), ConsensusModeIsMultiEra(CardanoModeIsMultiEra), anyAddressInEra, AnyCardanoEra(AnyCardanoEra), makeTransactionBodyAutoBalance, Tx, makeShelleyKeyWitness, makeSignedTransaction, displayError)
import Control.Monad.Trans.Except.Extra (firstExceptT, left, newExceptT, hoistEither)
import Cardano.CLI.Environment (readEnvSocketPath)
import Cardano.Prelude
import System.IO qualified as IO
import Cardano.CLI.Faucet.Types (FaucetWebError(..))
import Cardano.CLI.Faucet.Utils
import Cardano.CLI.Shelley.Run.Transaction
import Cardano.CLI.Types
import Data.Map.Strict qualified as Map
import Prelude qualified
import Data.Text qualified as T

txBuild :: IsShelleyBasedEra era
  => ShelleyBasedEra era
  -> ConsensusModeParams CardanoMode
  -> NetworkId
  -> (TxIn, TxOut CtxUTxO era)
  -> [TxOutAnyEra]
  -> TxOutChangeAddress
  -> ExceptT FaucetWebError IO (TxBody era)
txBuild sbe cModeParams networkId (txin, txout) txouts (TxOutChangeAddress changeAddr) = do
  -- TODO, use the main socket, dont make a new one
  SocketPath sockPath <- firstExceptT (FaucetWebErrorSocketNotFound . show) readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams networkId sockPath
  let era = shelleyBasedToCardanoEra sbe
  let dummyFee = Just $ Lovelace 0

  txBodyContent <- TxBodyContent
    <$> pure [(txin, BuildTxWith $ KeyWitness KeyWitnessForSpending)]
    <*> pure TxInsCollateralNone
    <*> pure TxInsReferenceNone
    <*> mapM (\x -> withExceptT (FaucetWebErrorTodo . renderShelleyTxCmdError) $ toTxOutInAnyEra era x) txouts
    <*> pure TxTotalCollateralNone
    <*> pure TxReturnCollateralNone
    <*> validateTxFee era dummyFee
    <*> noBoundsIfSupported era
    <*> pure TxMetadataNone
    <*> pure TxAuxScriptsNone
    <*> pure TxExtraKeyWitnessesNone
    <*> pure (BuildTxWith Nothing)
    <*> pure TxWithdrawalsNone
    <*> pure TxCertificatesNone
    <*> pure TxUpdateProposalNone
    <*> pure TxMintNone
    <*> pure TxScriptValidityNone

  eInMode <- case toEraInMode era CardanoMode of
    Just result -> return result
    Nothing -> left (FaucetWebErrorConsensusModeMismatchTxBalance (show $ AnyConsensusMode CardanoMode) (AnyCardanoEra era))

  let
    utxo = UTxO $ Map.fromList [ (txin, txout) ]

  (pparams, eraHistory, systemStart, stakePools) <-
    newExceptT . fmap (join . first (FaucetWebErrorAcquireFailure . show)) $
      executeLocalStateQueryExpr localNodeConnInfo Nothing $ \_ntcVersion -> runExceptT $ do
        --UTxO utxo <- firstExceptT (_ . ShelleyTxCmdTxSubmitErrorEraMismatch) . newExceptT . queryExpr
        --  $ QueryInEra eInMode $ QueryInShelleyBasedEra sbe
        --  $ QueryUTxO (QueryUTxOByTxIn (Set.singleton txin))

        --when (null utxo || not (txin `L.elem` Map.keys utxo)) $ do
          -- txout for txin does not exist
        --  left $ ShelleyTxCmdTxInsDoNotExist [txin]

        pparams <- firstExceptT (FaucetWebErrorEraMismatch . show) . newExceptT . queryExpr
          $ QueryInEra eInMode $ QueryInShelleyBasedEra sbe QueryProtocolParameters

        eraHistory <- lift . queryExpr $ QueryEraHistory CardanoModeIsMultiEra

        systemStart <- lift $ queryExpr QuerySystemStart

        stakePools <- firstExceptT (FaucetWebErrorEraMismatch . show) . ExceptT $
          queryExpr . QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryStakePools

        return (pparams, eraHistory, systemStart, stakePools)

  cAddr <- pure $ case anyAddressInEra era changeAddr of
    Just addr -> addr
    Nothing -> Prelude.error "txBuild: Byron address used: "

  (BalancedTxBody balancedTxBody _ _fee) <- firstExceptT (FaucetWebErrorAutoBalance . T.pack . displayError) . hoistEither $
    makeTransactionBodyAutoBalance eInMode systemStart eraHistory pparams stakePools utxo txBodyContent cAddr Nothing

  liftIO $ IO.putStrLn "Estimated transaction fee"
  return balancedTxBody

txSign :: IsShelleyBasedEra era
  => NetworkId
  -> TxBody era
  -> [SomeWitness]
  -> ExceptT ShelleyTxCmdError IO (Tx era)
txSign networkId txBody sks = do
  let (sksByron, sksShelley) = partitionSomeWitnesses $ map categoriseSomeWitness sks

  -- Byron witnesses require the network ID. This can either be provided
  -- directly or derived from a provided Byron address.
  byronWitnesses <- firstExceptT (ShelleyTxCmdBootstrapWitnessError) . hoistEither $
    mkShelleyBootstrapWitnesses (Just networkId) txBody sksByron

  let shelleyKeyWitnesses = map (makeShelleyKeyWitness txBody) sksShelley
  let tx = makeSignedTransaction (byronWitnesses ++ shelleyKeyWitnesses) txBody

  return tx
